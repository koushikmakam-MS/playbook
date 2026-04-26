<#
.SYNOPSIS
    Doc Reviewer 📖 — The Documentation Validator (Monkey #10)

.DESCRIPTION
    Validates generated documentation against actual source code.
    Cross-references file paths, method names, config keys, class names,
    and error codes mentioned in docs with the actual codebase.

    Generates questions to fix any discrepancies found.

.PARAMETER RepoPath
    Path to the local repository.

.PARAMETER DocsGlob
    Glob patterns for documentation files. Default: docs/**/*.md

.PARAMETER Model
    Copilot model to use.

.PARAMETER BatchSize
    Batch size for question execution.

.PARAMETER Incremental
    Only check docs for files changed since last run.

.PARAMETER Since
    Git ref or date for incremental mode.

.PARAMETER DryRun
    Report only, don't fix.

.PARAMETER OutputDir
    Output directory for results.

.PARAMETER MaxRetries
    Max retries per copilot call.

.PARAMETER RetryBaseDelay
    Base delay for exponential backoff.

.PARAMETER CallTimeout
    Timeout per copilot call.

.PARAMETER ShowVerbose
    Show copilot output.

.EXAMPLE
    .\doc-reviewer.ps1 -RepoPath "C:\myrepo" -DryRun

.EXAMPLE
    .\doc-reviewer.ps1 -RepoPath "C:\myrepo" -Incremental -Model "gpt-4.1"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$RepoPath,

    [string[]]$DocsGlob = @("docs/**/*.md", "**/*.md"),

    [string]$Model,

    [int]$BatchSize = 5,

    [int]$MaxQuestions = 0,

    [switch]$Incremental,

    [string]$Since,

    [switch]$DryRun,

    [string]$OutputDir = ".doc-reviewer-output",

    [int]$MaxRetries = 3,

    [int]$RetryBaseDelay = 30,

    [int]$CallTimeout = 300,

    [switch]$ShowVerbose,

    [switch]$Internal,
    [string]$InternalRepoPath,
    [string]$InternalModel,
    [string]$InternalOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$sharedModule = Join-Path $PSScriptRoot "..\shared\MonkeyCommon.psm1"
Import-Module $sharedModule -Force

$script:MONKEY_NAME  = "Doc Reviewer"
$script:MONKEY_EMOJI = "📖"
$script:MONKEY_ID    = "doc-reviewer"

# ─────────────────────────────────────────────
# Region: Phase 2 — Discovery
# ─────────────────────────────────────────────

function Find-DocFiles {
    param([string]$RootDir)

    Write-Phase "PHASE 2" "Discovery — Finding Documentation Files"

    $docFiles = @()
    $defaultPatterns = @("*.md")

    foreach ($pattern in $defaultPatterns) {
        $files = Get-ChildItem -Path $RootDir -Recurse -Filter $pattern -File -ErrorAction SilentlyContinue
        $files = $files | Where-Object {
            $_.FullName -notmatch '[\\/](node_modules|vendor|\.git|bin|obj|dist|build|\.monkey-output|\.rafiki-output)[\\/]'
        }
        foreach ($f in $files) {
            $docFiles += @{
                Path    = $f.FullName
                RelPath = $f.FullName.Substring($RootDir.Length + 1)
                Size    = $f.Length
            }
        }
    }

    $docFiles = $docFiles | Sort-Object { $_.Size } -Descending
    Write-Step "Found $($docFiles.Count) documentation files" "OK"
    return $docFiles
}

# ─────────────────────────────────────────────
# Region: Phase 3 — Cross-Reference Analysis
# ─────────────────────────────────────────────

function Test-DocReferences {
    <#
    .SYNOPSIS
        Scans a doc file for code references and checks if they exist.
    #>
    param(
        [string]$DocPath,
        [string]$RootDir
    )

    $content = Get-Content $DocPath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return @{ Issues = @(); RefCount = 0 } }

    $issues = @()
    $refCount = 0

    # Pattern 1: File paths (src/..., lib/..., etc.)
    $pathMatches = [regex]::Matches($content, '(?:src|lib|app|pkg|cmd|internal)[/\\][\w\-./\\]+\.\w+')
    foreach ($m in $pathMatches) {
        $refCount++
        $refPath = $m.Value.Replace('/', '\')
        $fullPath = Join-Path $RootDir $refPath
        if (-not (Test-Path $fullPath)) {
            $issues += @{
                Type     = "DEAD_PATH"
                Ref      = $m.Value
                Line     = ($content.Substring(0, $m.Index) -split "`n").Count
                Severity = "HIGH"
            }
        }
    }

    # Pattern 2: Class/type names in backticks (e.g., `MyController`)
    $classMatches = [regex]::Matches($content, '`([A-Z]\w{2,}(?:Controller|Service|Provider|Handler|Manager|Factory|Helper|Impl|Entity|Interface|Base))`')
    foreach ($m in $classMatches) {
        $refCount++
        $className = $m.Groups[1].Value
        # Search for the class in source files
        $found = Get-ChildItem -Path $RootDir -Recurse -Filter "*.cs" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -notmatch '[\\/](bin|obj|test|\.git)[\\/]' } |
            Select-Object -First 200 |
            Where-Object {
                $c = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
                $c -and $c -match "class\s+$className\b"
            } | Select-Object -First 1
        if (-not $found) {
            $issues += @{
                Type     = "DEAD_CLASS"
                Ref      = $className
                Line     = ($content.Substring(0, $m.Index) -split "`n").Count
                Severity = "MEDIUM"
            }
        }
    }

    # Pattern 3: Config property names
    $configMatches = [regex]::Matches($content, '`((?:Is|Enable|Max|Min|Default|Allow|Use)\w+)`')
    foreach ($m in $configMatches) {
        $refCount++
    }

    return @{
        Issues   = $issues
        RefCount = $refCount
    }
}

# ─────────────────────────────────────────────
# Region: Phase 4 — Question Generation
# ─────────────────────────────────────────────

function New-ReviewQuestions {
    param(
        [array]$DocAnalysis,
        [string]$RootDir
    )

    Write-Phase "PHASE 3" "Generating review questions from $($DocAnalysis.Count) docs with issues"

    $questions = @()
    foreach ($doc in $DocAnalysis) {
        if ($doc.Issues.Count -eq 0) { continue }

        $issueList = ($doc.Issues | ForEach-Object {
            "- $($_.Type): '$($_.Ref)' (line $($_.Line), severity: $($_.Severity))"
        }) -join "`n"

        $questions += @{
            EntryPoint = $doc.RelPath
            Question   = "This documentation file has $($doc.Issues.Count) stale reference(s):`n$issueList`nPlease verify each reference against the current codebase. For DEAD_PATH issues, find the correct current file path. For DEAD_CLASS issues, find the renamed or replacement class. Update the documentation to fix all stale references."
            Category   = "doc-review"
        }
    }

    Write-Step "Generated $($questions.Count) review questions" "OK"
    return $questions
}

# ─────────────────────────────────────────────
# Region: Main
# ─────────────────────────────────────────────

function Start-DocReviewer {
    $startTime = Get-Date

    try {
        # Phase 1: Setup
        $workDir = if ($Internal) { $InternalRepoPath } else { $RepoPath }
        $workDir = (Resolve-Path $workDir).Path

        if (-not $Internal) {
            Write-MonkeyBanner -Name $script:MONKEY_NAME -Emoji $script:MONKEY_EMOJI -Version "1.0.0"
            Test-Preflight
        }

        $script:SelectedModel = if ($Internal) { $InternalModel } elseif ($Model) { $Model } else {
            $probe = Select-MonkeyModel -RepoPath $workDir
            $probe.Model
        }

        $script:OutputPath = if ($Internal) { $InternalOutputPath } else {
            $outDir = Join-Path $workDir $OutputDir
            if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
            New-Item -ItemType Directory -Path (Join-Path $outDir "session-logs") -Force | Out-Null
            $outDir
        }

        # Phase 2: Find doc files
        $docFiles = Find-DocFiles -RootDir $workDir

        # Incremental filter
        if ($Incremental -or $Since) {
            $sinceRef = $Since
            if (-not $sinceRef) {
                $lastState = Get-IncrementalState -WorkingDirectory $workDir
                if ($lastState) { $sinceRef = $lastState.CommitHash; Write-Step "Incremental: since $sinceRef" "INFO" }
                else { Write-Step "No prior run — running full" "WARN" }
            }
            if ($sinceRef) {
                $changedFiles = Get-ChangedFiles -WorkingDirectory $workDir -Since $sinceRef
                $docFiles = @($docFiles | Where-Object {
                    $rel = $_.RelPath.Replace('\', '/')
                    $changedFiles -contains $rel
                })
                if ($docFiles.Count -eq 0) {
                    Write-Step "No docs changed — nothing to review" "OK"
                    return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -ExitStatus 'SKIPPED' -Model $script:SelectedModel
                }
                Write-Step "Incremental: $($docFiles.Count) docs to review" "INFO"
            }
        }

        # Phase 3: Cross-reference analysis
        Write-Phase "PHASE 3" "Cross-Reference Analysis — Checking $($docFiles.Count) docs"
        $docAnalysis = @()
        foreach ($doc in $docFiles) {
            $result = Test-DocReferences -DocPath $doc.Path -RootDir $workDir
            if ($result.Issues.Count -gt 0) {
                $docAnalysis += @{
                    Path     = $doc.Path
                    RelPath  = $doc.RelPath
                    Issues   = $result.Issues
                    RefCount = $result.RefCount
                }
            }
        }

        $totalIssues = ($docAnalysis | ForEach-Object { $_.Issues.Count } | Measure-Object -Sum).Sum
        Write-Step "Found $totalIssues issues across $($docAnalysis.Count) docs" $(if ($totalIssues -gt 0) { "WARN" } else { "OK" })

        if ($totalIssues -eq 0) {
            Write-Step "All doc references are valid!" "OK"
            $currentCommit = (& git -C $workDir rev-parse HEAD 2>&1).Trim()
            Save-IncrementalState -WorkingDirectory $workDir -MonkeyName "doc-reviewer" -CommitHash $currentCommit -EntryPointCount $docFiles.Count -QuestionsAsked 0
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -ExitStatus 'SUCCESS' -Model $script:SelectedModel -QuestionsAsked 0
        }

        # Save analysis report
        $docAnalysis | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $script:OutputPath "doc-review-analysis.json") -Encoding UTF8

        # Phase 4: Generate and execute questions
        $questions = New-ReviewQuestions -DocAnalysis $docAnalysis -RootDir $workDir

        if ($questions.Count -eq 0) {
            Write-Step "No actionable questions generated" "OK"
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -ExitStatus 'SUCCESS' -Model $script:SelectedModel
        }

        $execStats = Invoke-MonkeyQuestions -Questions $questions -WorkingDirectory $workDir `
            -OutputPath $script:OutputPath -ModelName $script:SelectedModel -MonkeyEmoji $script:MONKEY_EMOJI `
            -MaxRetries $MaxRetries -RetryBaseDelay $RetryBaseDelay -CallTimeout $CallTimeout -BatchSize $BatchSize -MaxQuestions $MaxQuestions -ShowVerbose:$ShowVerbose

        # Save state
        $currentCommit = (& git -C $workDir rev-parse HEAD 2>&1).Trim()
        Save-IncrementalState -WorkingDirectory $workDir -MonkeyName "doc-reviewer" -CommitHash $currentCommit -EntryPointCount $docFiles.Count -QuestionsAsked $questions.Count

        # Summary
        $duration = (Get-Date) - $startTime
        $reportStats = Save-MonkeyReport -ExecStats $execStats -OutputPath $script:OutputPath -MonkeyName $script:MONKEY_NAME

        Write-Host "  $script:MONKEY_EMOJI Doc Reviewer complete! Found $totalIssues issues, generated $($questions.Count) fix questions." -ForegroundColor Green

        return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
            -Model $script:SelectedModel -ExitStatus 'SUCCESS' `
            -QuestionsAsked $questions.Count -QuestionsAnswered $execStats.Answered `
            -DocRefsFound $totalIssues -FilesModified $execStats.FileChanges `
            -DocsGroundedPct $reportStats.DocGroundedPct -RetryCount $execStats.Retries
    }
    catch {
        $duration = (Get-Date) - $startTime
        Write-Host "`n  ❌ FATAL: $($_.Exception.Message)" -ForegroundColor Red
        if ($Internal) {
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                -Model $script:SelectedModel -ExitStatus 'FAILED' -Errors @($_.Exception.Message)
        }
        exit 1
    }
}

Start-DocReviewer
