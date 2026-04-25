<#
.SYNOPSIS
    Donkey Kong 🦍 — The Test Coverage Hunter (Monkey Army)
.DESCRIPTION
    Discovers test coverage gaps by mapping source→test files via naming conventions.
    Identifies untested files, under-tested files, and test-less directories.
    Generates targeted questions via Copilot to document testing strategy.
    Part of the Monkey Army 🐒🐵 framework (Phase 6).
.PARAMETER RepoUrl
    Git repo URL to clone.
.PARAMETER RepoPath
    Path to an already-cloned local repo. Skips clone.
.PARAMETER QuestionsPerFile
    Max questions per coverage gap. Default: 3.
.PARAMETER Model
    Copilot model override. Auto-probes if not specified.
.EXAMPLE
    .\donkey-kong.ps1 -RepoPath "C:\myrepo" -DryRun -QuestionsPerFile 3
.EXAMPLE
    .\donkey-kong.ps1 -RepoUrl "https://github.com/org/repo.git" -Commit
#>

[CmdletBinding()]
param(
    [string]$RepoUrl,
    [string]$ClonePath = ".\monkey-workspace",
    [string]$RepoPath,
    [string]$BaseBranch,
    [switch]$UseBaseBranch,
    [string]$BranchName,
    [string]$Model,
    [int]$QuestionsPerFile = 3,
    [switch]$DryRun,
    [switch]$Commit,
    [int]$MaxRetries = 3,
    [int]$RetryBaseDelay = 30,
    [int]$CallTimeout = 300,
    [int]$BatchSize = 5,
    [switch]$ShowVerbose,

    # Internal mode (called by orchestrator — skips setup/commit)
    [switch]$Internal,
    [string]$InternalRepoPath,
    [string]$InternalModel,
    [string]$InternalOutputPath
)

$ErrorActionPreference = "Stop"

# Import shared module
Import-Module (Join-Path $PSScriptRoot "..\shared\MonkeyCommon.psm1") -Force

# ── Constants ────────────────────────────────────────────────────────
$script:MONKEY_NAME = "Donkey Kong"; $script:MONKEY_EMOJI = "🦍"
$script:MONKEY_VERSION = "1.0.0";   $script:MONKEY_TAGLINE = "The Test Coverage Hunter"
$script:MONKEY_PREFIX = "donkey-kong"; $script:OUTPUT_DIR = ".monkey-output"

$script:TEST_PATTERNS = @(
    @{ Src = '(.+)\.cs$';   Test = @('$1Tests.cs','$1Test.cs','Test$1.cs') }
    @{ Src = '(.+)\.py$';   Test = @('test_$1.py','$1_test.py','tests/test_$1.py') }
    @{ Src = '(.+)\.ts$';   Test = @('$1.test.ts','$1.spec.ts','__tests__/$1.test.ts') }
    @{ Src = '(.+)\.js$';   Test = @('$1.test.js','$1.spec.js','__tests__/$1.test.js') }
    @{ Src = '(.+)\.java$'; Test = @('$1Test.java','$1Tests.java','Test$1.java') }
    @{ Src = '(.+)\.go$';   Test = @('$1_test.go') }
    @{ Src = '(.+)\.rb$';   Test = @('$1_spec.rb','test_$1.rb','$1_test.rb') }
    @{ Src = '(.+)\.rs$';   Test = @('$1_test.rs','tests/$1.rs') }
    @{ Src = '(.+)\.kt$';   Test = @('$1Test.kt','$1Tests.kt') }
    @{ Src = '(.+)\.php$';  Test = @('$1Test.php','$1_test.php') }
)

$script:METHOD_PATTERNS = @{
    '.cs'   = '(?m)^\s*public\s+(?:(?:static|virtual|override|async|abstract|sealed|new)\s+)*(?:Task<[^>]+>|Task|IActionResult|ActionResult[^)]*|[A-Za-z<>\[\],\s]+?)\s+(\w+)\s*\('
    '.py'   = '(?m)^(?:    |\t)?(?:async\s+)?def\s+(\w+)\s*\('; '.ts' = '(?m)(?:export\s+)?(?:async\s+)?(?:function\s+(\w+)|(\w+)\s*[=:]\s*(?:async\s+)?(?:function|\([^)]*\)\s*=>))'
    '.js'   = '(?m)(?:export\s+)?(?:async\s+)?(?:function\s+(\w+)|(\w+)\s*[=:]\s*(?:async\s+)?(?:function|\([^)]*\)\s*=>))'
    '.java' = '(?m)^\s*public\s+(?:\w+\s+)*(\w+)\s*\('; '.go' = '(?m)^func\s+(?:\([^)]+\)\s+)?(\w+)\s*\('
    '.rb'   = '(?m)^\s*def\s+(\w+)'; '.rs' = '(?m)^\s*pub\s+(?:async\s+)?fn\s+(\w+)\s*[<(]'
    '.kt'   = '(?m)^\s*(?:fun|suspend\s+fun)\s+(\w+)\s*\('; '.php' = '(?m)^\s*public\s+function\s+(\w+)\s*\('
}

$script:SOURCE_EXCLUDES = @(
    'bin/','obj/','node_modules/','vendor/','.git/','dist/','build/',
    '__pycache__/','target/','.gradle/','.monkey-output/','.rafiki-output/',
    '.abu-output/','.mojo-jojo-output/','.donkey-kong-output/','packages/','migrations/'
)

$script:TEST_DIR_NAMES = @(
    'test','tests','spec','specs','__tests__','test_','Tests',
    'UnitTests','IntegrationTests','unit_tests','integration_tests','testing'
)

# ── Phase 2 — Discovery ──────────────────────────────────────────────

function Get-PublicMethodCount {
    param([string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $pattern = $script:METHOD_PATTERNS[$ext]
    if (-not $pattern) { return 0 }
    $content = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return 0 }
    $matches_ = [regex]::Matches($content, $pattern)
    $names = @()
    foreach ($m in $matches_) {
        $name = if ($m.Groups[1].Success) { $m.Groups[1].Value } elseif ($m.Groups[2].Success) { $m.Groups[2].Value } else { $null }
        if ($name -and $name -notin $names -and $name -notmatch '^(if|else|for|while|switch|catch|try|using|get|set|var|let|const|class|new|return)$') { $names += $name }
    }
    return $names.Count
}

function Get-TestMethodCount {
    param([string]$FilePath)
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    $content = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return 0 }
    $tp = @{
        '.cs'='(?m)\[(Test|TestMethod|Fact|Theory|TestCase)\]'; '.py'='(?m)^\s*def\s+test_\w+'; '.ts'='(?m)\b(it|test)\s*\('; '.js'='(?m)\b(it|test)\s*\('
        '.java'='(?m)@(Test|ParameterizedTest)\b'; '.go'='(?m)^func\s+Test\w+\s*\('; '.rb'='(?m)\b(it|test|specify)\s+[''"]'
        '.rs'='(?m)#\[test\]'; '.kt'='(?m)@(Test|ParameterizedTest)\b'; '.php'='(?m)public\s+function\s+test\w+\s*\('
    }
    $pattern = $tp[$ext]; if (-not $pattern) { return 0 }
    return ([regex]::Matches($content, $pattern)).Count
}

function Find-CoverageGaps {
    param([string]$WorkDir)
    Write-Phase "PHASE 2" "Discovery — Mapping Source Files to Tests"

    Push-Location $WorkDir
    try { $allFiles = @(git ls-files 2>$null) | Where-Object { $_ } }
    finally { Pop-Location }
    if ($allFiles.Count -eq 0) { throw "No files found via git ls-files. Is this a git repository?" }

    $sourceExts = @('.cs','.py','.ts','.js','.java','.go','.rb','.rs','.kt','.php')
    $testIndicators = @('test','Test','spec','Spec','_test','.test.','.spec.','__tests__')
    $sourceFiles = @(); $testFiles = @()

    foreach ($f in $allFiles) {
        $ext = [System.IO.Path]::GetExtension($f).ToLower()
        if ($ext -notin $sourceExts) { continue }
        $excluded = $false
        foreach ($excl in $script:SOURCE_EXCLUDES) {
            if ($f -match [regex]::Escape($excl).Replace('/', '[/\\]')) { $excluded = $true; break }
        }
        if ($excluded) { continue }
        $isTest = $false
        foreach ($ind in $testIndicators) { if ($f -match [regex]::Escape($ind)) { $isTest = $true; break } }
        if ($isTest) { $testFiles += $f } else { $sourceFiles += $f }
    }
    Write-Step "Found $($sourceFiles.Count) source files and $($testFiles.Count) test files" "OK"

    # Build test file lookup
    $testLookup = @{}
    foreach ($tf in $testFiles) { $testLookup[[System.IO.Path]::GetFileName($tf).ToLower()] = $tf }

    $untested = @(); $underTested = @(); $testedCount = 0
    foreach ($src in $sourceFiles) {
        $srcName = [System.IO.Path]::GetFileNameWithoutExtension($src)
        $matchingPattern = $script:TEST_PATTERNS | Where-Object { $src -match $_.Src } | Select-Object -First 1
        if (-not $matchingPattern) { continue }
        $foundTest = $null
        foreach ($tmpl in $matchingPattern.Test) {
            $testName = [System.IO.Path]::GetFileName(($tmpl -replace '\$1', $srcName)).ToLower()
            if ($testLookup.ContainsKey($testName)) { $foundTest = $testLookup[$testName]; break }
        }
        $publicMethods = Get-PublicMethodCount -FilePath (Join-Path $WorkDir $src)
        if (-not $foundTest) {
            if ($publicMethods -gt 0) { $untested += @{ SourceFile=$src; PublicMethods=$publicMethods; GapType="UNTESTED" } }
        } else {
            $testMethods = Get-TestMethodCount -FilePath (Join-Path $WorkDir $foundTest)
            if ($testMethods -lt 3 -and $publicMethods -gt 0) {
                $underTested += @{ SourceFile=$src; TestFile=$foundTest; PublicMethods=$publicMethods; TestMethods=$testMethods; GapType="UNDER_TESTED" }
            } else { $testedCount++ }
        }
    }

    # Detect test-less directories
    $sourceDirs = @{}
    foreach ($src in $sourceFiles) { $dir = Split-Path $src -Parent; if (-not $dir) { $dir = '.' }; if (-not $sourceDirs.ContainsKey($dir)) { $sourceDirs[$dir] = 0 }; $sourceDirs[$dir]++ }
    $testDirSet = @{}
    foreach ($tf in $testFiles) { $dir = Split-Path $tf -Parent; while ($dir) { $testDirSet[$dir] = $true; $dir = Split-Path $dir -Parent } }

    $testlessDirs = @()
    foreach ($dir in $sourceDirs.Keys) {
        $hasTests = $false
        foreach ($td in $testDirSet.Keys) { if ($td -eq $dir -or $td.StartsWith("$dir/") -or $td.StartsWith("$dir\")) { $hasTests = $true; break } }
        if (-not $hasTests) {
            foreach ($tdn in $script:TEST_DIR_NAMES) {
                $sibling = Join-Path (Split-Path $dir -Parent) $tdn
                if ($testDirSet.ContainsKey($sibling)) { $hasTests = $true; break }
            }
        }
        if (-not $hasTests -and $sourceDirs[$dir] -ge 2) { $testlessDirs += @{ Directory=$dir; SourceCount=$sourceDirs[$dir]; GapType="TESTLESS_DIR" } }
    }

    Write-Host ""
    Write-Host "  🔍 Coverage Gap Discovery Complete" -ForegroundColor Cyan
    Write-Host "  ├─ ✅ Well-tested:    $testedCount files" -ForegroundColor Green
    Write-Host "  ├─ ❌ Untested:       $($untested.Count) files" -ForegroundColor $(if ($untested.Count -gt 0) { "Red" } else { "Green" })
    Write-Host "  ├─ ⚠️  Under-tested:   $($underTested.Count) files" -ForegroundColor $(if ($underTested.Count -gt 0) { "Yellow" } else { "Green" })
    Write-Host "  └─ 📁 Test-less dirs: $($testlessDirs.Count) directories" -ForegroundColor $(if ($testlessDirs.Count -gt 0) { "Yellow" } else { "Green" })

    if ($untested.Count -gt 0) {
        Write-Host ""; Write-Host "  Top untested:" -ForegroundColor White
        foreach ($u in $untested | Sort-Object { $_.PublicMethods } -Descending | Select-Object -First 10) {
            Write-Host "    ❌ [$($u.PublicMethods) methods] $($u.SourceFile)" -ForegroundColor DarkYellow
        }
        if ($untested.Count -gt 10) { Write-Host "    ... and $($untested.Count - 10) more" -ForegroundColor DarkGray }
    }

    $findings = @{ Untested=$untested; UnderTested=$underTested; TestlessDirs=$testlessDirs; TestedCount=$testedCount }
    $findings | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:OutputPath "coverage-gaps.json") -Encoding UTF8
    Write-Step "Saved coverage gap findings to coverage-gaps.json" "OK"
    return $findings
}

# ── Phase 3 — Question Generation ────────────────────────────────────

function New-CoverageQuestions {
    param([hashtable]$Findings, [string]$WorkingDirectory)
    $totalGaps = $Findings.Untested.Count + $Findings.UnderTested.Count + $Findings.TestlessDirs.Count
    Write-Phase "PHASE 3" "Question Generation — $totalGaps coverage gaps"
    if ($totalGaps -eq 0) { Write-Step "No coverage gaps found! 🎉" "OK"; return @() }

    $allQuestions = @(); $questionHashes = @{}; $currentGap = 0

    foreach ($gap in $Findings.Untested) {
        $currentGap++
        Write-Progress -Activity "Generating coverage questions" -Status "$currentGap/$totalGaps — $($gap.SourceFile)" -PercentComplete ([Math]::Round(($currentGap/$totalGaps)*100))
        $prompt = "Source file '$($gap.SourceFile)' has $($gap.PublicMethods) public methods but NO test file exists for it.`n`nGenerate exactly $QuestionsPerFile questions about test coverage gaps that would trigger documentation of testing strategy and required test cases. Focus on: what test cases are needed, edge cases/error paths, and mocking strategy.`n`nOutput ONLY a JSON array of strings. No explanation, no markdown fences."
        Write-Step "[$currentGap/$totalGaps] Untested: $($gap.SourceFile) ($($gap.PublicMethods) methods)..." "INFO"
        $result = Invoke-CopilotWithRetry -Prompt $prompt -ModelName $script:SelectedModel -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout
        foreach ($q in (ConvertFrom-CopilotQuestionResponse -Result $result -Label $gap.SourceFile)) {
            $hash = Get-QuestionHash -Text $q
            if (-not $questionHashes.ContainsKey($hash)) { $questionHashes[$hash] = $true; $allQuestions += @{ EntryPoint=$gap.SourceFile; Question=$q; Category="UNTESTED" } }
        }
    }

    foreach ($gap in $Findings.UnderTested) {
        $currentGap++
        Write-Progress -Activity "Generating coverage questions" -Status "$currentGap/$totalGaps — $($gap.SourceFile)" -PercentComplete ([Math]::Round(($currentGap/$totalGaps)*100))
        $qCount = [Math]::Min(2, $QuestionsPerFile)
        $prompt = "Test file '$($gap.TestFile)' for source '$($gap.SourceFile)' has only $($gap.TestMethods) test methods for $($gap.PublicMethods) public methods.`n`nGenerate exactly $qCount questions about missing test coverage. Focus on which public methods lack coverage and what additional scenarios should be tested.`n`nOutput ONLY a JSON array of strings. No explanation, no markdown fences."
        Write-Step "[$currentGap/$totalGaps] Under-tested: $($gap.SourceFile) ($($gap.TestMethods)/$($gap.PublicMethods))..." "INFO"
        $result = Invoke-CopilotWithRetry -Prompt $prompt -ModelName $script:SelectedModel -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout
        foreach ($q in (ConvertFrom-CopilotQuestionResponse -Result $result -Label $gap.SourceFile)) {
            $hash = Get-QuestionHash -Text $q
            if (-not $questionHashes.ContainsKey($hash)) { $questionHashes[$hash] = $true; $allQuestions += @{ EntryPoint=$gap.SourceFile; Question=$q; Category="UNDER_TESTED" } }
        }
    }

    foreach ($gap in $Findings.TestlessDirs) {
        $currentGap++
        Write-Progress -Activity "Generating coverage questions" -Status "$currentGap/$totalGaps — $($gap.Directory)" -PercentComplete ([Math]::Round(($currentGap/$totalGaps)*100))
        $qCount = [Math]::Min(2, $QuestionsPerFile)
        $prompt = "Directory '$($gap.Directory)' has $($gap.SourceCount) source files but no test directory or test files nearby.`n`nGenerate exactly $qCount questions about testing strategy for this module. Focus on appropriate testing approach and required test infrastructure.`n`nOutput ONLY a JSON array of strings. No explanation, no markdown fences."
        Write-Step "[$currentGap/$totalGaps] Test-less dir: $($gap.Directory) ($($gap.SourceCount) files)..." "INFO"
        $result = Invoke-CopilotWithRetry -Prompt $prompt -ModelName $script:SelectedModel -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout
        foreach ($q in (ConvertFrom-CopilotQuestionResponse -Result $result -Label $gap.Directory)) {
            $hash = Get-QuestionHash -Text $q
            if (-not $questionHashes.ContainsKey($hash)) { $questionHashes[$hash] = $true; $allQuestions += @{ EntryPoint=$gap.Directory; Question=$q; Category="TESTLESS_DIR" } }
        }
    }

    Write-Progress -Activity "Generating coverage questions" -Completed
    $allQuestions = @($allQuestions | Where-Object { $_.Category -eq "UNTESTED" } | Sort-Object { Get-Random }) +
                   @($allQuestions | Where-Object { $_.Category -eq "UNDER_TESTED" } | Sort-Object { Get-Random }) +
                   @($allQuestions | Where-Object { $_.Category -eq "TESTLESS_DIR" } | Sort-Object { Get-Random })
    $allQuestions | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:OutputPath "questions.json") -Encoding UTF8
    Write-Step "Saved $($allQuestions.Count) coverage questions to questions.json" "OK"
    return $allQuestions
}

# ── Helpers ──────────────────────────────────────────────────────────

function Get-QuestionHash { param([string]$Text)
    [System.BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text.ToLower().Trim()))).Substring(0, 16)
}

function ConvertFrom-CopilotQuestionResponse { param($Result, [string]$Label)
    if (-not $Result -or -not $Result.Success) { Write-Step "Failed for $Label" "ERROR"; return @() }
    $questions = @()
    try { $out = $Result.Output.Trim(); if ($out -match '\[[\s\S]*\]') { $questions = @($Matches[0] | ConvertFrom-Json) } }
    catch {
        Write-Step "JSON parse failed for $Label — line fallback" "WARN"
        foreach ($line in ($Result.Output -split "`n")) { if ($line -match '^\s*\d+[\.\)]\s*(.+)') { $questions += $Matches[1].Trim() } }
    }
    if ($questions.Count -eq 0) { Write-Step "No questions parsed for $Label" "WARN" } else { Write-Step "Generated $($questions.Count) questions" "OK" }
    return $questions
}

# ── Main Orchestrator ────────────────────────────────────────────────

function Start-DonkeyKong {
    $startTime = Get-Date
    try {
        if (-not $Internal) {
            Write-MonkeyBanner -Name $script:MONKEY_NAME -Emoji $script:MONKEY_EMOJI -Version $script:MONKEY_VERSION -Tagline $script:MONKEY_TAGLINE
            Test-Preflight
            $setup = Invoke-MonkeySetup -RepoUrl $RepoUrl -ClonePath $ClonePath -RepoPath $RepoPath `
                -BaseBranch $BaseBranch -UseBaseBranch:$UseBaseBranch -BranchName $BranchName `
                -BranchPrefix $script:MONKEY_PREFIX -OutputDirName $script:OUTPUT_DIR
            $workDir = $setup.WorkDir; $script:BranchName = $setup.Branch; $script:OutputPath = $setup.OutputPath
            $script:SelectedModel = Select-MonkeyModel -UserModel $Model -WorkingDirectory $workDir
            Test-CopilotInRepo -WorkingDirectory $workDir
        } else {
            Write-Phase "DONKEY KONG" "Running in internal mode (orchestrated)"
            $workDir = $InternalRepoPath; $script:SelectedModel = $InternalModel
            $script:OutputPath = $InternalOutputPath; $script:BranchName = ''
            if (-not (Test-Path $script:OutputPath)) { New-Item -ItemType Directory -Path $script:OutputPath -Force | Out-Null }
            New-Item -ItemType Directory -Path (Join-Path $script:OutputPath "session-logs") -Force | Out-Null
        }

        $findings = Find-CoverageGaps -WorkDir $workDir
        $questions = New-CoverageQuestions -Findings $findings -WorkingDirectory $workDir

        if ($questions.Count -eq 0) {
            $duration = (Get-Date) - $startTime
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration -Model $script:SelectedModel -ExitStatus 'SUCCESS' -QuestionsAsked 0 -QuestionsAnswered 0
        }

        $execStats = Invoke-MonkeyQuestions -Questions $questions -WorkingDirectory $workDir `
            -OutputPath $script:OutputPath -ModelName $script:SelectedModel -MonkeyEmoji $script:MONKEY_EMOJI `
            -MaxRetries $MaxRetries -RetryBaseDelay $RetryBaseDelay -CallTimeout $CallTimeout -BatchSize $BatchSize -ShowVerbose:$ShowVerbose

        $filesChanged = 0
        if (-not $Internal) {
            $filesChanged = Invoke-MonkeyCommit -WorkingDirectory $workDir -OutputDirName $script:OUTPUT_DIR `
                -MonkeyName $script:MONKEY_NAME -MonkeyEmoji $script:MONKEY_EMOJI -BranchName $script:BranchName `
                -ModelName $script:SelectedModel -QuestionsAnswered $execStats.Answered -DryRun:$DryRun -Commit:$Commit
        }

        $duration = (Get-Date) - $startTime
        $reportStats = Save-MonkeyReport -ExecStats $execStats -OutputPath $script:OutputPath -MonkeyName $script:MONKEY_NAME
        $runStats = @{
            "01_UntestedFiles"=$findings.Untested.Count; "02_UnderTestedFiles"=$findings.UnderTested.Count
            "03_TestlessDirs"=$findings.TestlessDirs.Count; "04_WellTestedFiles"=$findings.TestedCount
            "05_QuestionsGenerated"=$questions.Count; "06_QuestionsAnswered"=$execStats.Answered
            "07_QuestionsFailed"=$execStats.Failed; "08_TotalRetries"=$execStats.Retries
            "09_FilesChanged"=$filesChanged; "10_DocGrounded"=$execStats.DocGroundedCount
            "11_ModelUsed"=if ($script:SelectedModel) { $script:SelectedModel } else { "(default)" }
            "12_Branch"=$script:BranchName; "13_Duration"="{0:hh\:mm\:ss}" -f $duration
        }
        $runStats | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:OutputPath "summary.json") -Encoding UTF8
        Write-MonkeySummary -Stats $runStats -Emoji $script:MONKEY_EMOJI
        Write-Host "  $($script:MONKEY_EMOJI) Donkey Kong complete!" -ForegroundColor Green

        return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
            -Model $script:SelectedModel -ExitStatus 'SUCCESS' `
            -QuestionsAsked $questions.Count -QuestionsAnswered $execStats.Answered `
            -DocRefsFound $execStats.DocGroundedCount -FilesModified $filesChanged `
            -DocsGroundedPct $reportStats.DocGroundedPct -RetryCount $execStats.Retries
    }
    catch {
        $duration = (Get-Date) - $startTime
        Write-Host "`n  ❌ FATAL: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Stack: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
        if ($Internal) {
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                -Model $script:SelectedModel -ExitStatus 'FAILED' -Errors @($_.Exception.Message)
        }
        exit 1
    }
}

Start-DonkeyKong
