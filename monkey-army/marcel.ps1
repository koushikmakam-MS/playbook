<#
.SYNOPSIS
    Marcel 🙈 — The Stale Doc Detective (Monkey Army, Phase 7)
.DESCRIPTION
    Discovers stale docs by extracting code references (file paths, class names,
    method names, config keys) and verifying them against the codebase. Flags dead
    refs, scores staleness, generates questions to trigger doc cleanup.
.PARAMETER RepoUrl
    Git repo URL to clone.
.PARAMETER ClonePath
    Local path for clone. Defaults to .\monkey-workspace
.PARAMETER RepoPath
    Path to an already-cloned local repo. Skips clone.
.PARAMETER QuestionsPerDoc
    Number of questions per stale doc. Default 3.
.EXAMPLE
    .\marcel.ps1 -RepoPath "C:\myrepo" -DryRun -QuestionsPerDoc 3
.EXAMPLE
    .\marcel.ps1 -RepoUrl "https://github.com/org/repo.git" -Commit -Model "claude-sonnet-4"
#>

param(
    [string]$RepoUrl,
    [string]$ClonePath = ".\monkey-workspace",
    [string]$RepoPath,
    [string]$BaseBranch,
    [switch]$UseBaseBranch,
    [string]$BranchName,
    [string]$Model,
    [int]$QuestionsPerDoc = 3,
    [switch]$DryRun,
    [switch]$Commit,
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

$ErrorActionPreference = "Stop"

# Import shared module
$sharedModule = Join-Path $PSScriptRoot "..\shared\MonkeyCommon.psm1"
if (-not (Test-Path $sharedModule)) {
    throw "Shared module not found at $sharedModule. Ensure monkey-army/shared/ exists."
}
Import-Module $sharedModule -Force

# ── Constants ────────────────────────────────────────────────────────
$script:MONKEY_NAME    = "Marcel"
$script:MONKEY_EMOJI   = "🙈"
$script:MONKEY_VERSION = "1.0.0"
$script:MONKEY_TAGLINE = "The Stale Doc Detective"
$script:OUTPUT_DIR     = ".monkey-output"

$script:DOC_DIR_PATTERNS = @('^docs[/\\]', '^doc[/\\]', '^wiki[/\\]', '^documentation[/\\]',
    '^guides[/\\]', '^knowledge[/\\]', '^copilot-docs[/\\]', '^agent-docs[/\\]', '^kb[/\\]', '^design[/\\]', '^specs[/\\]', '^notes[/\\]')

$script:EXCLUDE_PATTERNS = @('bin[/\\]', 'obj[/\\]', 'node_modules[/\\]', 'vendor[/\\]', '\.git[/\\]',
    'dist[/\\]', 'build[/\\]', '__pycache__[/\\]', 'target[/\\]', '\.gradle[/\\]',
    '\.monkey-output[/\\]', '\.rafiki-output[/\\]', '\.abu-output[/\\]', '\.mojo-jojo-output[/\\]')

# Code file extensions for reference validation
$script:CODE_EXTENSIONS = @('cs', 'py', 'ts', 'js', 'java', 'go', 'rb', 'rs', 'kt', 'php')

# ─────────────────────────────────────────────
# Region: Phase 2 — Discovery
# ─────────────────────────────────────────────

function Get-TrackedFiles {
    param([string]$WorkDir)
    $files = & git -C $WorkDir ls-files 2>$null
    $fileSet = @{}
    foreach ($f in $files) {
        $fileSet[$f.Replace('\', '/')] = $true
    }
    return $fileSet
}

function Find-DocFiles {
    param([string]$WorkDir, [hashtable]$TrackedFiles)
    $docFiles = @()
    foreach ($file in $TrackedFiles.Keys) {
        # Skip excluded paths
        $skip = $false
        foreach ($excl in $script:EXCLUDE_PATTERNS) {
            if ($file -match $excl) { $skip = $true; break }
        }
        if ($skip) { continue }

        $isDoc = $false

        # Markdown/rst/txt in doc-like directories
        if ($file -match '\.(md|rst|txt)$') {
            foreach ($dirPat in $script:DOC_DIR_PATTERNS) {
                if ($file -match $dirPat) { $isDoc = $true; break }
            }
            # Top-level markdown files (README, CONTRIBUTING, etc.)
            if (-not $isDoc -and $file -match '\.md$' -and ($file -split '[/\\]').Count -le 2) {
                $isDoc = $true
            }
        }

        if ($isDoc) { $docFiles += $file }
    }
    return $docFiles
}

function Extract-CodeReferences {
    param([string]$Content)
    $refs = @{}

    # File paths: src/Something.cs, models/user.py, etc.
    $extPattern = ($script:CODE_EXTENSIONS | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $filePathRegex = "[\w\-./\\]+\.($extPattern)"
    $matches_ = [regex]::Matches($Content, $filePathRegex)
    foreach ($m in $matches_) {
        $val = $m.Value.Trim()
        if ($val.Length -ge 5) { $refs[$val] = "filepath" }
    }

    # Backtick-quoted identifiers: `UserController`, `OrderService`
    $backtickMatches = [regex]::Matches($Content, '`(\w{3,})`')
    foreach ($m in $backtickMatches) {
        $val = $m.Groups[1].Value
        # Filter out common non-code words
        if ($val -notmatch '^(true|false|null|none|string|int|bool|void|class|return|public|private)$') {
            $refs[$val] = "identifier"
        }
    }

    # ALL_CAPS config keys (at least two segments: SOME_CONFIG_KEY)
    $capsMatches = [regex]::Matches($Content, '\b([A-Z][A-Z0-9]+(?:_[A-Z0-9]+)+)\b')
    foreach ($m in $capsMatches) {
        $refs[$m.Groups[1].Value] = "configkey"
    }

    # Method names: DoSomething(), handle_request()
    $methodMatches = [regex]::Matches($Content, '\b(\w+)\(\)')
    foreach ($m in $methodMatches) {
        $val = $m.Groups[1].Value
        if ($val.Length -ge 3 -and $val -notmatch '^(e\.g|i\.e|etc)$') {
            $refs[$val] = "method"
        }
    }

    return $refs
}

function Test-ReferenceExists {
    param([string]$Ref, [string]$RefType, [hashtable]$TrackedFiles, [string]$WorkDir)

    if ($RefType -eq "filepath") {
        $normalized = $Ref.Replace('\', '/')
        # Direct match
        if ($TrackedFiles.ContainsKey($normalized)) { return $true }
        # Partial/suffix match
        foreach ($f in $TrackedFiles.Keys) {
            if ($f -like "*$normalized") { return $true }
        }
        return $false
    }

    # For identifiers, config keys, methods — grep the codebase
    $grepResult = & git -C $WorkDir grep -l -q $Ref -- '*.cs' '*.py' '*.ts' '*.js' '*.java' '*.go' '*.rb' '*.rs' '*.kt' '*.php' 2>$null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-Discovery {
    param([string]$WorkDir)

    Write-Phase "PHASE 2" "Discovery — Scanning docs for stale code references"

    $trackedFiles = Get-TrackedFiles -WorkDir $WorkDir
    Write-Step "Indexed $($trackedFiles.Count) tracked files" "OK"

    $docFiles = Find-DocFiles -WorkDir $WorkDir -TrackedFiles $trackedFiles
    Write-Step "Found $($docFiles.Count) doc files to analyze" "OK"

    if ($docFiles.Count -eq 0) {
        Write-Step "No doc files found in doc-like directories" "WARN"
        return @()
    }

    $docAnalysis = @()
    $currentDoc = 0

    foreach ($docFile in $docFiles) {
        $currentDoc++
        $fullPath = Join-Path $WorkDir $docFile
        if (-not (Test-Path $fullPath)) { continue }

        $content = Get-Content $fullPath -Raw -ErrorAction SilentlyContinue
        if (-not $content -or $content.Length -lt 50) { continue }

        $refs = Extract-CodeReferences -Content $content
        if ($refs.Count -eq 0) { continue }

        Write-Host "`r  📄 [$currentDoc/$($docFiles.Count)] $docFile ($($refs.Count) refs)..." -NoNewline -ForegroundColor DarkGray

        $aliveRefs = @()
        $deadRefs = @()

        foreach ($refKey in $refs.Keys) {
            $exists = Test-ReferenceExists -Ref $refKey -RefType $refs[$refKey] -TrackedFiles $trackedFiles -WorkDir $WorkDir
            if ($exists) {
                $aliveRefs += @{ Ref = $refKey; Type = $refs[$refKey] }
            } else {
                $deadRefs += @{ Ref = $refKey; Type = $refs[$refKey] }
            }
        }

        $totalRefs = $aliveRefs.Count + $deadRefs.Count
        $staleness = if ($totalRefs -gt 0) { [Math]::Round(($deadRefs.Count / $totalRefs) * 100, 1) } else { 0 }

        if ($deadRefs.Count -gt 0) {
            $docAnalysis += @{
                DocFile       = $docFile
                TotalRefs     = $totalRefs
                AliveRefs     = $aliveRefs.Count
                DeadRefs      = $deadRefs.Count
                DeadRefList   = $deadRefs
                AliveRefList  = $aliveRefs
                StalenessPct  = $staleness
            }
        }
    }

    Write-Host ""  # end progress line
    $docAnalysis = @($docAnalysis | Sort-Object { $_.StalenessPct } -Descending)

    # Display table
    Write-Host ""
    Write-Host "  ┌──────────────────────────────────────────────┬───────┬───────┬───────┬───────────┐" -ForegroundColor DarkGray
    Write-Host "  │ Doc File                                     │ Total │ Alive │ Dead  │ Staleness │" -ForegroundColor DarkGray
    Write-Host "  ├──────────────────────────────────────────────┼───────┼───────┼───────┼───────────┤" -ForegroundColor DarkGray
    foreach ($doc in $docAnalysis | Select-Object -First 30) {
        $name = $doc.DocFile
        if ($name.Length -gt 44) { $name = "..." + $name.Substring($name.Length - 41) }
        $staleStr = "{0,6:N1}%" -f $doc.StalenessPct
        $staleColor = if ($doc.StalenessPct -gt 50) { "Red" } elseif ($doc.StalenessPct -gt 25) { "Yellow" } else { "Green" }
        Write-Host ("  │ {0,-44} │ {1,5} │ {2,5} │ {3,5} │ " -f $name, $doc.TotalRefs, $doc.AliveRefs, $doc.DeadRefs) -ForegroundColor DarkGray -NoNewline
        Write-Host ("{0,-9}" -f $staleStr) -ForegroundColor $staleColor -NoNewline
        Write-Host " │" -ForegroundColor DarkGray
    }
    if ($docAnalysis.Count -gt 30) {
        Write-Host "  │ ... and $($docAnalysis.Count - 30) more                                                          │" -ForegroundColor DarkGray
    }
    Write-Host "  └──────────────────────────────────────────────┴───────┴───────┴───────┴───────────┘" -ForegroundColor DarkGray

    $totalDead = ($docAnalysis | Measure-Object -Property DeadRefs -Sum).Sum
    $highStale = @($docAnalysis | Where-Object { $_.StalenessPct -gt 50 }).Count
    Write-Step "Stale docs: $($docAnalysis.Count) with dead refs ($totalDead total dead refs, $highStale critically stale)" "OK"

    return $docAnalysis
}

# ─────────────────────────────────────────────
# Region: Phase 3 — Question Generation
# ─────────────────────────────────────────────

function New-StaleDocQuestions {
    param([array]$DocAnalysis, [string]$WorkingDirectory)

    Write-Phase "PHASE 3" "Question Generation — Targeting $($DocAnalysis.Count) stale docs"

    $allQuestions = @()
    $questionHashes = @{}
    $totalDocs = $DocAnalysis.Count
    $currentDoc = 0

    foreach ($doc in $DocAnalysis) {
        $currentDoc++
        $pct = [Math]::Round(($currentDoc / $totalDocs) * 100)
        Write-Progress -Activity "Generating stale-doc questions" -Status "$currentDoc/$totalDocs — $($doc.DocFile)" -PercentComplete $pct

        $deadRefSummary = ($doc.DeadRefList | ForEach-Object { "'$($_.Ref)' ($($_.Type))" }) -join ", "

        # Questions for docs with dead refs
        $genPrompt = @"
Doc '$($doc.DocFile)' references these code symbols that NO LONGER EXIST in the codebase:
Dead references: $deadRefSummary

The doc has $($doc.TotalRefs) total code references, $($doc.DeadRefs) are dead ($($doc.StalenessPct)% stale).

Generate exactly $QuestionsPerDoc questions about these stale references that would trigger documentation cleanup and update.
Questions should ask copilot to:
- Find the replacement or successor for deleted/renamed symbols
- Update the doc to reflect the current codebase state
- Remove references to code that no longer exists

Output ONLY a JSON array of strings. No explanation, no markdown fences, no preamble.
Example: ["The doc references 'OldController' which no longer exists. What replaced it and how should the doc be updated?"]
"@

        # Additional questions for highly stale docs (>50%)
        if ($doc.StalenessPct -gt 50) {
            $genPrompt += @"

ADDITIONALLY: This doc is $($doc.StalenessPct)% stale with $($doc.DeadRefs) dead references out of $($doc.TotalRefs) total.
Add 2 more questions about whether this doc needs a complete rewrite or targeted updates.
Total output should be $($QuestionsPerDoc + 2) questions.
"@
        }

        Write-Step "[$currentDoc/$totalDocs] Generating questions for $($doc.DocFile) ($($doc.StalenessPct)% stale)..." "INFO"

        $result = Invoke-CopilotWithRetry -Prompt $genPrompt -ModelName $script:SelectedModel `
            -WorkingDirectory $WorkingDirectory -Retries $MaxRetries `
            -BaseDelay $RetryBaseDelay -Timeout $CallTimeout

        if (-not $result.Success) {
            Write-Step "Failed to generate questions for $($doc.DocFile): $($result.Error)" "ERROR"
            continue
        }

        $questions = @()
        try {
            $output = $result.Output.Trim()
            if ($output -match '\[[\s\S]*\]') {
                $jsonMatch = $Matches[0]
                $questions = @($jsonMatch | ConvertFrom-Json)
            }
        }
        catch {
            Write-Step "JSON parse failed for $($doc.DocFile). Falling back to line parsing." "WARN"
            $questions = @()
            $lines = $result.Output -split "`n"
            foreach ($line in $lines) {
                if ($line -match '^\s*\d+[\.\)]\s*(.+)') {
                    $questions += $Matches[1].Trim()
                }
            }
        }

        if ($questions.Count -eq 0) {
            Write-Step "No questions parsed for $($doc.DocFile)" "WARN"
            continue
        }

        foreach ($q in $questions) {
            $hash = [System.BitConverter]::ToString(
                [System.Security.Cryptography.SHA256]::Create().ComputeHash(
                    [System.Text.Encoding]::UTF8.GetBytes($q.ToLower().Trim())
                )
            ).Substring(0, 16)

            if (-not $questionHashes.ContainsKey($hash)) {
                $questionHashes[$hash] = $true
                $allQuestions += @{
                    EntryPoint = $doc.DocFile
                    Question   = $q
                    Category   = if ($doc.StalenessPct -gt 50) { "CRITICALLY_STALE" } else { "STALE_REF" }
                }
            }
        }

        Write-Step "Generated $($questions.Count) unique questions ($($allQuestions.Count) total)" "OK"

        # Early exit if MaxQuestions cap reached
        if ($MaxQuestions -gt 0 -and $allQuestions.Count -ge $MaxQuestions) {
            Write-Step "Reached MaxQuestions cap ($MaxQuestions) — stopping question generation early" "OK"
            break
        }
    }

    Write-Progress -Activity "Generating stale-doc questions" -Completed

    # Shuffle — critically stale first, then random
    $allQuestions = @($allQuestions | Where-Object { $_.Category -eq "CRITICALLY_STALE" } | Sort-Object { Get-Random }) +
                   @($allQuestions | Where-Object { $_.Category -ne "CRITICALLY_STALE" } | Sort-Object { Get-Random })

    $questionsPath = Join-Path $script:OutputPath "questions.json"
    $allQuestions | ConvertTo-Json -Depth 5 | Set-Content $questionsPath -Encoding UTF8
    Write-Step "Saved $($allQuestions.Count) stale-doc questions to questions.json" "OK"

    return $allQuestions
}

# ─────────────────────────────────────────────
# Region: Main Orchestrator
# ─────────────────────────────────────────────

function Start-Marcel {
    $startTime = Get-Date

    try {
        # ── Mode split: standalone vs internal ──
        if (-not $Internal) {
            Write-MonkeyBanner -Name $script:MONKEY_NAME -Emoji $script:MONKEY_EMOJI -Version $script:MONKEY_VERSION -Tagline $script:MONKEY_TAGLINE
            Test-Preflight
            $setup = Invoke-MonkeySetup -RepoUrl $RepoUrl -ClonePath $ClonePath -RepoPath $RepoPath `
                -BaseBranch $BaseBranch -UseBaseBranch:$UseBaseBranch -BranchName $BranchName `
                -BranchPrefix "marcel" -OutputDirName $script:OUTPUT_DIR
            $workDir = $setup.WorkDir
            $script:BranchName = $setup.Branch
            $script:OutputPath = $setup.OutputPath
            $script:SelectedModel = Select-MonkeyModel -UserModel $Model -WorkingDirectory $workDir
            Test-CopilotInRepo -WorkingDirectory $workDir
        }
        else {
            Write-Phase "MARCEL" "Running in internal mode (orchestrated)"
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

        # Phase 2: Discovery — find stale docs
        $docAnalysis = Invoke-Discovery -WorkDir $workDir

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
                $docAnalysis = @($docAnalysis | Where-Object { $_.DocFile -in $changedFiles })
                if ($docAnalysis.Count -eq 0) {
                    Write-Step "No stale docs in changed files — nothing to do" "OK"
                    $duration = (Get-Date) - $startTime
                    return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                        -Model $script:SelectedModel -ExitStatus 'SUCCESS' -QuestionsAsked 0 -QuestionsAnswered 0
                }
            }
        }

        if ($docAnalysis.Count -eq 0) {
            Write-Step "No stale documentation found! All references are current. 🎉" "OK"
            $duration = (Get-Date) - $startTime
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                -Model $script:SelectedModel -ExitStatus 'SUCCESS' -QuestionsAsked 0 -QuestionsAnswered 0
        }

        # Save discovery results
        $discoveryReport = $docAnalysis | ForEach-Object {
            @{
                DocFile      = $_.DocFile
                TotalRefs    = $_.TotalRefs
                AliveRefs    = $_.AliveRefs
                DeadRefs     = $_.DeadRefs
                StalenessPct = $_.StalenessPct
                DeadRefList  = $_.DeadRefList
            }
        }
        $discoveryReport | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:OutputPath "discovery.json") -Encoding UTF8

        # Phase 3: Question generation
        if ($PreGenQuestions -and $PreGenQuestions.Count -gt 0) {
            $questions = $PreGenQuestions
            Write-Step "Using $($PreGenQuestions.Count) pre-generated questions" "OK"
        } else {
            $savedQ = Get-QuestionCheckpoint -OutputPath $script:OutputPath
            if ($savedQ -and $savedQ.Count -gt 0 -and -not $GenOnly) {
                $questions = $savedQ
                Write-Step "Loaded $($savedQ.Count) questions from checkpoint — skipping generation" "OK"
            } else {
                $questions = New-StaleDocQuestions -DocAnalysis $docAnalysis -WorkingDirectory $workDir
                Save-QuestionCheckpoint -OutputPath $script:OutputPath -Questions $questions
            }
        }

        if ($questions.Count -eq 0) {
            Write-Step "No questions generated from stale docs" "WARN"
            $duration = (Get-Date) - $startTime
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                -Model $script:SelectedModel -ExitStatus 'SUCCESS' -QuestionsAsked 0 -QuestionsAnswered 0
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
            $filesChanged = Invoke-MonkeyCommit -WorkingDirectory $workDir -OutputDirName $script:OUTPUT_DIR `
                -MonkeyName $script:MONKEY_NAME -MonkeyEmoji $script:MONKEY_EMOJI -BranchName $script:BranchName `
                -ModelName $script:SelectedModel -QuestionsAnswered $execStats.Answered -DryRun:$DryRun -Commit:$Commit
        }

        # Summary + Report
        $duration = (Get-Date) - $startTime
        $reportStats = Save-MonkeyReport -ExecStats $execStats -OutputPath $script:OutputPath -MonkeyName $script:MONKEY_NAME

        $totalDead = ($docAnalysis | Measure-Object -Property DeadRefs -Sum).Sum
        $highStale = @($docAnalysis | Where-Object { $_.StalenessPct -gt 50 }).Count

        $runStats = @{
            "01_StaleDocsFound"     = $docAnalysis.Count
            "02_TotalDeadRefs"      = $totalDead
            "03_CriticallyStale"    = $highStale
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
        Write-Host "  $($script:MONKEY_EMOJI) Marcel complete!" -ForegroundColor Green

        # Return standardized result
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

Start-Marcel
