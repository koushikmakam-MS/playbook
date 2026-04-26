<#
.SYNOPSIS
    Abu 🐵 — The Doc Gap Detective (Monkey Army)

.DESCRIPTION
    Abu discovers documentation gaps by cross-referencing code entry points against existing docs
    and checking doc completeness. Generates targeted questions to fill those gaps, feeds them
    to GitHub Copilot CLI, and tracks whether docs are created/updated.

    Two gap detection strategies:
    1. Cross-reference: Code files without matching docs → "undocumented code" gaps
    2. Completeness: Existing docs missing key sections → "incomplete doc" gaps

    Part of the Monkey Army 🐒🐵 framework.

.PARAMETER RepoUrl
    Git repo URL to clone.

.PARAMETER ClonePath
    Local path for clone. Defaults to .\monkey-workspace

.PARAMETER RepoPath
    Path to an already-cloned local repo. Skips clone.

.PARAMETER QuestionsPerGap
    Number of targeted questions per identified gap (default 5).

.PARAMETER BranchName
    Working branch name. Defaults to abu/<timestamp>.

.PARAMETER BaseBranch
    Branch to pull latest from. If not provided, prompts the user.

.PARAMETER DryRun
    Stage changes only, don't commit.

.PARAMETER Commit
    Auto-commit doc changes to the branch.

.PARAMETER Model
    Copilot model to use. If not specified, auto-probes best available.

.PARAMETER OutputDir
    Directory for session transcripts. Defaults to .abu-output/

.PARAMETER MaxRetries
    Max retries per copilot call. Default 3.

.PARAMETER RetryBaseDelay
    Base delay in seconds for exponential backoff. Default 30.

.PARAMETER CallTimeout
    Hard timeout per copilot -p call. Default 300 (5 min).

.PARAMETER UseBaseBranch
    Work directly on the base branch.

.PARAMETER ShowVerbose
    Show copilot output in real-time.

.EXAMPLE
    .\abu.ps1 -RepoPath "C:\myrepo" -DryRun -QuestionsPerGap 3

.EXAMPLE
    .\abu.ps1 -RepoUrl "https://github.com/org/repo.git" -Commit -Model "claude-sonnet-4"
#>

[CmdletBinding(DefaultParameterSetName = 'Clone')]
param(
    [Parameter(ParameterSetName = 'Clone')]
    [string]$RepoUrl,

    [Parameter(ParameterSetName = 'Clone')]
    [string]$ClonePath = ".\monkey-workspace",

    [Parameter(ParameterSetName = 'Local', Mandatory)]
    [string]$RepoPath,

    [int]$QuestionsPerGap = 5,

    [string]$BranchName,

    [string]$BaseBranch,

    [switch]$UseBaseBranch,

    [switch]$DryRun,

    [switch]$Commit,

    [string]$Model,

    [string]$OutputDir = ".abu-output",

    [int]$MaxRetries = 3,

    [int]$RetryBaseDelay = 30,

    [int]$CallTimeout = 300,

    [int]$BatchSize = 5,

    [int]$MaxQuestions = 0,

    [switch]$Incremental,

    [string]$Since,

    [switch]$ShowVerbose,

    # Parallel gen mode
    [switch]$GenOnly,
    [array]$PreGenQuestions = @(),

    # Internal mode (called by orchestrator — skips setup/commit)
    [switch]$Internal,
    [string]$InternalRepoPath,
    [string]$InternalModel,
    [string]$InternalOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Import shared module
$sharedModule = Join-Path $PSScriptRoot "..\shared\MonkeyCommon.psm1"
if (-not (Test-Path $sharedModule)) {
    throw "Shared module not found at $sharedModule. Ensure monkey-army/shared/ exists."
}
Import-Module $sharedModule -Force

# ─────────────────────────────────────────────
# Region: Constants
# ─────────────────────────────────────────────

$script:MONKEY_NAME = "Abu"
$script:MONKEY_EMOJI = "🐵"
$script:MONKEY_VERSION = "1.0.0"
$script:MONKEY_TAGLINE = "The Doc Gap Detective"

# Doc structure patterns to auto-detect
$script:DOC_PATTERNS = @(
    "docs/**/*.md"
    "doc/**/*.md"
    "wiki/**/*.md"
    "documentation/**/*.md"
    "guides/**/*.md"
    "*.md"
)

# Sections that well-documented code should have
$script:EXPECTED_SECTIONS = @(
    @{ Name = "Overview/Summary";     Patterns = @('overview', 'summary', 'introduction', 'about', '# \w') }
    @{ Name = "Architecture/Design";  Patterns = @('architect', 'design', 'structure', 'diagram', 'flow') }
    @{ Name = "API/Endpoints";        Patterns = @('api', 'endpoint', 'route', 'request', 'response') }
    @{ Name = "Error Handling";       Patterns = @('error', 'exception', 'fault', 'failure', 'retry') }
    @{ Name = "Configuration";        Patterns = @('config', 'setting', 'parameter', 'environment') }
    @{ Name = "Dependencies";         Patterns = @('depend', 'prerequisite', 'require', 'import') }
    @{ Name = "Testing";              Patterns = @('test', 'coverage', 'unit test', 'integration') }
    @{ Name = "Security";             Patterns = @('security', 'auth', 'permission', 'rbac', 'credential') }
)

# Code file patterns (entry points to cross-reference against docs)
$script:CODE_PATTERNS = @(
    # C#
    "**/*Controller*.cs"
    "**/*Handler*.cs"
    "**/*Service*.cs"
    "**/*Provider*.cs"
    # Python
    "**/views.py"
    "**/routes.py"
    "**/*controller*.py"
    "**/*router*.py"
    # JavaScript / TypeScript
    "**/*controller*.js"
    "**/*controller*.ts"
    "**/*router*.js"
    "**/*router*.ts"
    # Java / Kotlin
    "**/*Controller*.java"
    "**/*Resource*.java"
    "**/*Controller*.kt"
    # Go
    "**/*handler*.go"
    "**/*controller*.go"
    "**/*server*.go"
    # Ruby
    "**/*controller*.rb"
    "**/routes.rb"
    # PHP
    "**/*Controller*.php"
    "**/*Handler*.php"
    # Rust
    "**/*handler*.rs"
    "**/*controller*.rs"
    "**/*routes*.rs"
)

# ─────────────────────────────────────────────
# Region: Phase 2 — Doc Discovery
# ─────────────────────────────────────────────

function Get-DocStructure {
    <#
    .SYNOPSIS
        Discovers the documentation structure of the repo.
        Returns: doc files, doc directories, README locations, index files.
    #>
    param([string]$RootDir)

    Write-Phase "PHASE 2" "Doc Discovery — Scanning Documentation Structure"

    $docFiles = @()
    $docDirs = @()

    # Find all markdown files
    $allMd = Get-ChildItem -Path $RootDir -Recurse -Filter "*.md" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules|vendor|\.git|dist|build|\.mojo-jojo-output|\.abu-output|\.rafiki-output|\.monkey-output|__pycache__|target|\.gradle)[\\/]' }

    foreach ($f in $allMd) {
        $relPath = $f.FullName.Substring($RootDir.Length + 1)
        $content = Get-Content $f.FullName -Raw -ErrorAction SilentlyContinue
        $lineCount = if ($content) { ($content -split "`n").Count } else { 0 }

        # Classify the doc
        $isIndex = $f.Name -match '^(README|INDEX|TOC|SUMMARY|doc.?index|doc.?registry)\.md$'
        $isTopLevel = ($relPath -split '[\\/]').Count -le 2

        $docFiles += @{
            Path      = $f.FullName
            RelPath   = $relPath
            Name      = $f.Name
            LineCount = $lineCount
            IsIndex   = $isIndex
            IsTopLevel = $isTopLevel
            Content   = $content
            Dir       = Split-Path $relPath -Parent
        }
    }

    # Identify doc directories
    $docDirs = @($docFiles | ForEach-Object { $_.Dir } | Where-Object { $_ } | Sort-Object -Unique)

    # Summary
    Write-Step "Found $($docFiles.Count) markdown files across $($docDirs.Count) directories" "OK"

    $indexFiles = @($docFiles | Where-Object { $_.IsIndex })
    if ($indexFiles.Count -gt 0) {
        Write-Step "Index files: $($indexFiles.Count)" "OK"
        foreach ($idx in $indexFiles | Select-Object -First 10) {
            Write-Host "    → $($idx.RelPath)" -ForegroundColor DarkGray
        }
    }
    else {
        Write-Step "No index/README files found — doc structure may be flat" "WARN"
    }

    # Show doc directory tree
    Write-Host ""
    Write-Host "  Doc directories:" -ForegroundColor Cyan
    foreach ($dir in $docDirs | Select-Object -First 20) {
        $count = @($docFiles | Where-Object { $_.Dir -eq $dir }).Count
        Write-Host "    📁 $dir ($count files)" -ForegroundColor DarkGray
    }
    if ($docDirs.Count -gt 20) {
        Write-Host "    ... and $($docDirs.Count - 20) more" -ForegroundColor DarkGray
    }

    return @{
        Files      = $docFiles
        Dirs       = $docDirs
        IndexFiles = $indexFiles
    }
}

# ─────────────────────────────────────────────
# Region: Phase 3 — Gap Analysis
# ─────────────────────────────────────────────

function Find-DocGaps {
    <#
    .SYNOPSIS
        Cross-references code entry points against docs AND checks doc completeness.
        Returns a list of gaps, each with type, severity, and targeted questions.
    #>
    param(
        [string]$RootDir,
        [hashtable]$DocStructure,
        [string]$WorkingDirectory
    )

    Write-Phase "PHASE 3" "Gap Analysis — Finding Documentation Gaps"

    $gaps = @()

    # ── Strategy 1: Cross-reference — find undocumented code ──
    Write-Step "Strategy 1: Cross-referencing code vs docs..." "INFO"

    $codeFiles = @()
    foreach ($pattern in $script:CODE_PATTERNS) {
        $parts = $pattern -split '/'
        $filter = $parts[-1]
        $found = Get-ChildItem -Path $RootDir -Recurse -Filter $filter -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules|vendor|\.git|dist|build|test|tests)[\\/]' }
        $codeFiles += $found
    }
    $codeFiles = $codeFiles | Sort-Object FullName -Unique

    Write-Step "Found $($codeFiles.Count) code files to cross-reference" "INFO"

    # Build a searchable doc content index
    $docContent = ($DocStructure.Files | ForEach-Object { $_.Content }) -join "`n"
    $docPaths = $DocStructure.Files | ForEach-Object { $_.RelPath.ToLower() }

    foreach ($codeFile in $codeFiles) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($codeFile.Name)
        $relPath = $codeFile.FullName.Substring($RootDir.Length + 1)

        # Check if any doc references this file by name (case-insensitive)
        $isDocumented = $false

        # Check 1: File name mentioned in any doc
        if ($docContent -match [regex]::Escape($baseName)) {
            $isDocumented = $true
        }

        # Check 2: A doc file exists with a similar name
        $docNameVariants = @(
            "$baseName.md".ToLower()
            "$($baseName -replace 'Controller|Handler|Service|Provider', '').md".ToLower()
            "$($baseName.ToLower() -replace '([a-z])([A-Z])', '$1-$2').md".ToLower()
        )
        foreach ($variant in $docNameVariants) {
            if ($docPaths | Where-Object { $_ -like "*$variant*" }) {
                $isDocumented = $true
                break
            }
        }

        if (-not $isDocumented) {
            $gaps += @{
                Type       = "UNDOCUMENTED_CODE"
                Severity   = "HIGH"
                Target     = $relPath
                TargetName = $baseName
                Reason     = "No documentation references found for '$baseName'"
                Questions  = @() # Will be populated below
            }
        }
    }

    $undocumentedCount = @($gaps | Where-Object { $_.Type -eq "UNDOCUMENTED_CODE" }).Count
    Write-Step "Found $undocumentedCount undocumented code files" $(if ($undocumentedCount -gt 0) { "WARN" } else { "OK" })

    # ── Strategy 2: Completeness — check existing docs for missing sections ──
    Write-Step "Strategy 2: Checking doc completeness..." "INFO"

    foreach ($doc in $DocStructure.Files) {
        if (-not $doc.Content -or $doc.LineCount -lt 10) { continue } # Skip tiny files

        $missingSections = @()
        foreach ($section in $script:EXPECTED_SECTIONS) {
            $found = $false
            foreach ($pattern in $section.Patterns) {
                if ($doc.Content -match $pattern) {
                    $found = $true
                    break
                }
            }
            if (-not $found) {
                $missingSections += $section.Name
            }
        }

        # Only flag if more than half of expected sections are missing
        if ($missingSections.Count -gt ($script:EXPECTED_SECTIONS.Count / 2)) {
            $gaps += @{
                Type       = "INCOMPLETE_DOC"
                Severity   = "MEDIUM"
                Target     = $doc.RelPath
                TargetName = $doc.Name
                Reason     = "Missing sections: $($missingSections -join ', ')"
                MissingSections = $missingSections
                Questions  = @()
            }
        }
    }

    $incompleteCount = @($gaps | Where-Object { $_.Type -eq "INCOMPLETE_DOC" }).Count
    Write-Step "Found $incompleteCount incomplete docs" $(if ($incompleteCount -gt 0) { "WARN" } else { "OK" })

    # ── Display gap summary ──
    Write-Host ""
    Write-Host "  ┌──────────────────────┬──────────┬─────────────────────────────────────────────┐" -ForegroundColor DarkGray
    Write-Host "  │ Type                 │ Severity │ Target                                      │" -ForegroundColor DarkGray
    Write-Host "  ├──────────────────────┼──────────┼─────────────────────────────────────────────┤" -ForegroundColor DarkGray
    foreach ($gap in $gaps | Select-Object -First 30) {
        $target = $gap.Target
        if ($target.Length -gt 43) { $target = "..." + $target.Substring($target.Length - 40) }
        $sevColor = if ($gap.Severity -eq "HIGH") { "Red" } else { "Yellow" }
        Write-Host ("  │ {0,-20} │ " -f $gap.Type) -ForegroundColor DarkGray -NoNewline
        Write-Host ("{0,-8}" -f $gap.Severity) -ForegroundColor $sevColor -NoNewline
        Write-Host (" │ {0,-43} │" -f $target) -ForegroundColor DarkGray
    }
    if ($gaps.Count -gt 30) {
        Write-Host "  │ ... and $($gaps.Count - 30) more                                                         │" -ForegroundColor DarkGray
    }
    Write-Host "  └──────────────────────┴──────────┴─────────────────────────────────────────────┘" -ForegroundColor DarkGray

    Write-Step "Total gaps: $($gaps.Count) ($undocumentedCount undocumented + $incompleteCount incomplete)" "OK"

    return $gaps
}

# ─────────────────────────────────────────────
# Region: Phase 3b — Gap-Targeted Question Generation
# ─────────────────────────────────────────────

function New-GapQuestions {
    <#
    .SYNOPSIS
        Generates targeted questions designed to fill specific doc gaps.
        Batches multiple gaps per Copilot call (default 10) to reduce API calls.
        For undocumented code: asks about architecture, API, error handling.
        For incomplete docs: asks about specific missing sections.
    #>
    param(
        [array]$Gaps,
        [string]$WorkingDirectory,
        [int]$GapBatchSize = 10
    )

    Write-Phase "PHASE 3b" "Gap-Targeted Question Generation ($($Gaps.Count) gaps, batch=$GapBatchSize)"

    $allQuestions = @()
    $questionHashes = @{}
    $totalGaps = $Gaps.Count
    $processedGaps = 0

    # Split gaps into batches for fewer Copilot calls
    $batches = @()
    for ($i = 0; $i -lt $Gaps.Count; $i += $GapBatchSize) {
        $end = [Math]::Min($i + $GapBatchSize, $Gaps.Count)
        $batches += ,@($Gaps[$i..($end - 1)])
    }

    $totalBatches = $batches.Count
    Write-Step "Batching $totalGaps gaps into $totalBatches Copilot calls (${GapBatchSize}/batch)" "INFO"

    for ($batchIdx = 0; $batchIdx -lt $totalBatches; $batchIdx++) {
        $batch = $batches[$batchIdx]
        $batchNum = $batchIdx + 1
        $processedGaps += $batch.Count
        $pct = [Math]::Round(($processedGaps / $totalGaps) * 100)
        Write-Progress -Activity "Generating gap-filling questions" -Status "Batch $batchNum/$totalBatches ($processedGaps/$totalGaps gaps)" -PercentComplete $pct

        # Build a combined prompt for all gaps in this batch
        $gapDescriptions = @()
        foreach ($gap in $batch) {
            if ($gap.Type -eq "UNDOCUMENTED_CODE") {
                $gapDescriptions += "- FILE: `"$($gap.Target)`" — UNDOCUMENTED. Generate $QuestionsPerGap questions covering: purpose, architecture, APIs, error handling, config, testing."
            }
            elseif ($gap.Type -eq "INCOMPLETE_DOC") {
                $missingSections = $gap.MissingSections -join ", "
                $gapDescriptions += "- DOC: `"$($gap.Target)`" — INCOMPLETE, missing: $missingSections. Generate $QuestionsPerGap questions targeting those missing sections."
            }
        }
        $gapList = $gapDescriptions -join "`n"

        $genPrompt = @"
Generate documentation questions for these $($batch.Count) code/doc gaps:

$gapList

For each gap, generate exactly $QuestionsPerGap questions that would produce complete documentation when answered.
Questions must be answerable by reading the codebase.

Output ONLY a JSON object where each key is the file path and each value is an array of question strings.
No explanation, no markdown fences.

Example:
{"src/Controllers/FooController.cs": ["What is the request flow?", "How are errors handled?"], "docs/bar.md": ["What config does it depend on?"]}
"@

        Write-Step "[Batch $batchNum/$totalBatches] Generating questions for $($batch.Count) gaps ($processedGaps/$totalGaps)..." "INFO"

        $result = Invoke-CopilotWithRetry -Prompt $genPrompt -ModelName $script:SelectedModel -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout

        if (-not $result.Success) {
            Write-Step "Batch $batchNum failed: $($result.Error). Falling back to per-gap generation." "WARN"
            # Fallback: generate per-gap for this batch only
            foreach ($gap in $batch) {
                $fallbackQuestions = New-SingleGapQuestions -Gap $gap -WorkingDirectory $WorkingDirectory
                foreach ($fq in $fallbackQuestions) {
                    $hash = Get-QuestionHash $fq.Question
                    if (-not $questionHashes.ContainsKey($hash)) {
                        $questionHashes[$hash] = $true
                        $allQuestions += $fq
                    }
                }
            }
            continue
        }

        # Parse batched JSON response: { "filepath": ["q1", "q2"], ... }
        $parsed = $null
        try {
            $output = $result.Output.Trim()
            if ($output -match '\{[\s\S]*\}') {
                $parsed = $Matches[0] | ConvertFrom-Json
            }
        }
        catch {
            Write-Step "JSON parse failed for batch $batchNum. Falling back to flat array parse." "WARN"
        }

        if ($null -ne $parsed) {
            # Structured response — map questions to their gap targets
            foreach ($gap in $batch) {
                $target = $gap.Target
                $questions = @()

                # Try exact match first, then partial match
                if ($parsed.PSObject.Properties.Name -contains $target) {
                    $questions = @($parsed.$target)
                }
                else {
                    $targetName = [System.IO.Path]::GetFileName($target)
                    foreach ($key in $parsed.PSObject.Properties.Name) {
                        if ($key -like "*$targetName*" -or $key -like "*$($gap.TargetName)*") {
                            $questions = @($parsed.$key)
                            break
                        }
                    }
                }

                foreach ($q in $questions) {
                    if ([string]::IsNullOrWhiteSpace($q)) { continue }
                    $hash = Get-QuestionHash $q
                    if (-not $questionHashes.ContainsKey($hash)) {
                        $questionHashes[$hash] = $true
                        $allQuestions += @{
                            EntryPoint = $target
                            Language   = "doc-gap"
                            Question   = $q
                            Category   = $gap.Type
                            GapType    = $gap.Type
                            Severity   = $gap.Severity
                        }
                    }
                }
            }
        }
        else {
            # Flat array fallback — assign questions round-robin to gaps
            $flatQuestions = @()
            try {
                if ($output -match '\[[\s\S]*\]') {
                    $flatQuestions = @($Matches[0] | ConvertFrom-Json)
                }
            }
            catch { }

            if ($flatQuestions.Count -gt 0) {
                $qPerGap = [Math]::Max(1, [Math]::Floor($flatQuestions.Count / $batch.Count))
                $qIdx = 0
                foreach ($gap in $batch) {
                    $assigned = 0
                    while ($qIdx -lt $flatQuestions.Count -and $assigned -lt $qPerGap) {
                        $q = $flatQuestions[$qIdx]
                        $qIdx++
                        $assigned++
                        if ([string]::IsNullOrWhiteSpace($q)) { continue }
                        $hash = Get-QuestionHash $q
                        if (-not $questionHashes.ContainsKey($hash)) {
                            $questionHashes[$hash] = $true
                            $allQuestions += @{
                                EntryPoint = $gap.Target
                                Language   = "doc-gap"
                                Question   = $q
                                Category   = $gap.Type
                                GapType    = $gap.Type
                                Severity   = $gap.Severity
                            }
                        }
                    }
                }
            }
            else {
                Write-Step "No questions parsed for batch $batchNum" "WARN"
            }
        }

        Write-Step "Batch $batchNum complete ($($allQuestions.Count) total questions)" "OK"

        # Early exit if MaxQuestions cap reached
        if ($MaxQuestions -gt 0 -and $allQuestions.Count -ge $MaxQuestions) {
            Write-Step "Reached MaxQuestions cap ($MaxQuestions) — stopping question generation early" "OK"
            break
        }
    }

    Write-Progress -Activity "Generating gap-filling questions" -Completed

    # Shuffle — high severity first, then random within severity
    $allQuestions = @($allQuestions | Where-Object { $_.Severity -eq "HIGH" } | Sort-Object { Get-Random }) +
                   @($allQuestions | Where-Object { $_.Severity -ne "HIGH" } | Sort-Object { Get-Random })

    $questionsPath = Join-Path $script:OutputPath "questions.json"
    $allQuestions | ConvertTo-Json -Depth 5 | Set-Content $questionsPath -Encoding UTF8
    Write-Step "Saved $($allQuestions.Count) gap-filling questions to questions.json" "OK"

    return $allQuestions
}

function Get-QuestionHash {
    <#
    .SYNOPSIS
        Returns a short SHA256 hash for deduplication of question text.
    #>
    param([string]$Text)
    return [System.BitConverter]::ToString(
        [System.Security.Cryptography.SHA256]::Create().ComputeHash(
            [System.Text.Encoding]::UTF8.GetBytes($Text.ToLower().Trim())
        )
    ).Substring(0, 16)
}

function New-SingleGapQuestions {
    <#
    .SYNOPSIS
        Fallback: generates questions for a single gap when batched call fails.
    #>
    param(
        [hashtable]$Gap,
        [string]$WorkingDirectory
    )

    $genPrompt = ""
    if ($Gap.Type -eq "UNDOCUMENTED_CODE") {
        $genPrompt = @"
The file '$($Gap.Target)' has NO documentation. Generate exactly $QuestionsPerGap questions that would produce complete documentation.
Focus on: purpose, architecture, APIs, error handling, config, testing.
Output ONLY a JSON array of strings.
"@
    }
    elseif ($Gap.Type -eq "INCOMPLETE_DOC") {
        $missingSections = $Gap.MissingSections -join ", "
        $genPrompt = @"
The doc '$($Gap.Target)' is INCOMPLETE, missing: $missingSections
Generate exactly $QuestionsPerGap questions targeting those missing sections.
Output ONLY a JSON array of strings.
"@
    }

    $result = Invoke-CopilotWithRetry -Prompt $genPrompt -ModelName $script:SelectedModel -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout
    $questions = @()

    if ($result.Success) {
        try {
            $output = $result.Output.Trim()
            if ($output -match '\[[\s\S]*\]') {
                $questions = @($Matches[0] | ConvertFrom-Json)
            }
        }
        catch { }
    }

    return @($questions | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        @{
            EntryPoint = $Gap.Target
            Language   = "doc-gap"
            Question   = $_
            Category   = $Gap.Type
            GapType    = $Gap.Type
            Severity   = $Gap.Severity
        }
    })
}

# ─────────────────────────────────────────────
# Region: Main Orchestrator
# ─────────────────────────────────────────────

function Start-Abu {
    $startTime = Get-Date

    try {
        # ── Mode split: standalone vs internal ──
        if (-not $Internal) {
            Write-MonkeyBanner -Name $script:MONKEY_NAME -Emoji $script:MONKEY_EMOJI -Version $script:MONKEY_VERSION -Tagline $script:MONKEY_TAGLINE
            Test-Preflight
            $setup = Invoke-MonkeySetup -RepoUrl $RepoUrl -ClonePath $ClonePath -RepoPath $RepoPath `
                -BaseBranch $BaseBranch -UseBaseBranch:$UseBaseBranch -BranchName $BranchName `
                -BranchPrefix "abu" -OutputDirName $OutputDir
            $workDir = $setup.WorkDir
            $script:BranchName = $setup.Branch
            $script:OutputPath = $setup.OutputPath
            $script:SelectedModel = Select-MonkeyModel -UserModel $Model -WorkingDirectory $workDir
            Test-CopilotInRepo -WorkingDirectory $workDir
        }
        else {
            Write-Phase "ABU" "Running in internal mode (orchestrated)"
            $workDir = $InternalRepoPath
            $script:SelectedModel = $InternalModel
            $script:OutputPath = $InternalOutputPath
            $script:BranchName = ''
            if (-not (Test-Path $script:OutputPath)) { New-Item -ItemType Directory -Path $script:OutputPath -Force | Out-Null }
            New-Item -ItemType Directory -Path (Join-Path $script:OutputPath "session-logs") -Force | Out-Null
        }

        # Fast-path: GenOnly + checkpoint exists → skip discovery entirely
        if ($GenOnly) {
            $savedQ = Get-QuestionCheckpoint -OutputPath $script:OutputPath
            if ($savedQ -and $savedQ.Count -gt 0) {
                Write-Step "Loaded $($savedQ.Count) questions from checkpoint — skipping discovery" "OK"
                return @{ Questions = $savedQ; Status = 'gen-complete'; MonkeyName = $script:MONKEY_NAME; Count = $savedQ.Count }
            }
        }

        # Phase 2: Doc Discovery
        $docStructure = Get-DocStructure -RootDir $workDir

        # Phase 3: Gap Analysis
        $gaps = Find-DocGaps -RootDir $workDir -DocStructure $docStructure -WorkingDirectory $workDir

        # Incremental filter
        if ($Incremental -or $Since) {
            $sinceRef = $Since
            if (-not $sinceRef) {
                $lastState = Get-IncrementalState -WorkingDirectory $workDir
                if ($lastState) {
                    $sinceRef = $lastState.CommitHash
                    Write-Step "Incremental: using last run commit $sinceRef" "INFO"
                }
                else {
                    Write-Step "No prior run found — running full" "WARN"
                }
            }
            if ($sinceRef) {
                $changedFiles = Get-ChangedFiles -WorkingDirectory $workDir -Since $sinceRef
                $gaps = @($gaps | Where-Object { $_.Target -in $changedFiles })
                if ($gaps.Count -eq 0) {
                    Write-Step "No gaps in changed files — nothing to do" "OK"
                    $duration = (Get-Date) - $startTime
                    return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                        -Model $script:SelectedModel -ExitStatus 'SUCCESS' -QuestionsAsked 0 -QuestionsAnswered 0
                }
            }
        }

        if ($gaps.Count -eq 0) {
            Write-Step "No documentation gaps found! 🎉" "OK"
            $duration = (Get-Date) - $startTime
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                -Model $script:SelectedModel -ExitStatus 'SUCCESS' -QuestionsAsked 0 -QuestionsAnswered 0
        }

        # Save gap analysis
        $gapReport = $gaps | ForEach-Object {
            @{ Type = $_.Type; Severity = $_.Severity; Target = $_.Target; Reason = $_.Reason }
        }
        $gapReport | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:OutputPath "gap-analysis.json") -Encoding UTF8

        # Phase 3b: Generate gap-targeted questions
        if ($PreGenQuestions -and $PreGenQuestions.Count -gt 0) {
            $questions = $PreGenQuestions
            Write-Step "Using $($PreGenQuestions.Count) pre-generated questions" "OK"
        } else {
            $savedQ = Get-QuestionCheckpoint -OutputPath $script:OutputPath
            if ($savedQ -and $savedQ.Count -gt 0 -and -not $GenOnly) {
                $questions = $savedQ
                Write-Step "Loaded $($savedQ.Count) questions from checkpoint — skipping generation" "OK"
            } else {
                $questions = New-GapQuestions -Gaps $gaps -WorkingDirectory $workDir
                Save-QuestionCheckpoint -OutputPath $script:OutputPath -Questions $questions
            }
        }

        # GenOnly mode — return questions without answering
        if ($GenOnly) {
            return @{ Questions = $questions; Status = 'gen-complete'; MonkeyName = $script:MONKEY_NAME; Count = $questions.Count }
        }

        # Phase 4: Execution (shared)
        $docDirs = Get-DocDirectories -RootDir $workDir
        $execStats = Invoke-MonkeyQuestions -Questions $questions -WorkingDirectory $workDir `
            -OutputPath $script:OutputPath -ModelName $script:SelectedModel -MonkeyEmoji $script:MONKEY_EMOJI `
            -MaxRetries $MaxRetries -RetryBaseDelay $RetryBaseDelay -CallTimeout $CallTimeout -BatchSize $BatchSize -MaxQuestions $MaxQuestions `
            -DocDirectories $docDirs -ShowVerbose:$ShowVerbose

        # Phase 5: Commit/Stage (standalone only)
        $filesChanged = 0
        if (-not $Internal) {
            $filesChanged = Invoke-MonkeyCommit -WorkingDirectory $workDir -OutputDirName $OutputDir `
                -MonkeyName $script:MONKEY_NAME -MonkeyEmoji $script:MONKEY_EMOJI -BranchName $script:BranchName `
                -ModelName $script:SelectedModel -QuestionsAnswered $execStats.Answered -DryRun:$DryRun -Commit:$Commit
        }

        # Summary + Report
        $duration = (Get-Date) - $startTime
        $reportStats = Save-MonkeyReport -ExecStats $execStats -OutputPath $script:OutputPath -MonkeyName $script:MONKEY_NAME

        $runStats = @{
            "01_GapsFound"          = $gaps.Count
            "02_Undocumented"       = @($gaps | Where-Object { $_.Type -eq "UNDOCUMENTED_CODE" }).Count
            "03_IncompleteDocs"     = @($gaps | Where-Object { $_.Type -eq "INCOMPLETE_DOC" }).Count
            "04_QuestionsGenerated" = $questions.Count
            "05_QuestionsAnswered"  = $execStats.Answered
            "06_QuestionsFailed"    = $execStats.Failed
            "07_TotalRetries"       = $execStats.Retries
            "08_FilesChanged"       = $filesChanged
            "09_DocGrounded"        = $execStats.DocGroundedCount
            "10_ModelUsed"          = if ($script:SelectedModel) { $script:SelectedModel } else { "(default)" }
            "11_Branch"             = $script:BranchName
            "12_Duration"           = "{0:hh\:mm\:ss}" -f $duration
        }
        $runStats | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $script:OutputPath "summary.json") -Encoding UTF8
        Write-MonkeySummary -Stats $runStats -Emoji $script:MONKEY_EMOJI
        Write-Host "  $($script:MONKEY_EMOJI) Abu complete!" -ForegroundColor Green

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

Start-Abu
