<#
.SYNOPSIS
    Curious George 🐵 — The Deep Auditor (Monkey Army, Phase 8)
.DESCRIPTION
    3-pass autonomous doc gap finder in agent mode.
    Pass 0: Discovery (undocumented controllers). Pass 1: Breadth (all domains).
    Pass 2: Depth (drill weak domains). Standalone or orchestrator-called (-Internal).
.EXAMPLE
    .\curious-george.ps1 -RepoPath "C:\myrepo" -Commit -Difficulty deep -DiscoveryMode full
.EXAMPLE
    .\curious-george.ps1 -Internal -InternalRepoPath "C:\myrepo" -InternalModel "claude-sonnet-4" -InternalOutputPath "C:\out"
#>

param(
    [string]$RepoUrl,
    [string]$ClonePath = ".\monkey-workspace",
    [string]$RepoPath,
    [string]$BaseBranch,
    [switch]$UseBaseBranch,
    [string]$BranchName,
    [string]$Model,
    [int]$Timeout = 7200,
    [switch]$DryRun,
    [switch]$Commit,
    # George-specific config (pre-filled from Get-ArmyConfig wizard)
    [int]$QuestionsPerDomain = 5,
    [string]$FocusArea = '',
    [string]$Difficulty = 'deep',
    [int]$MaxSkip = 3,
    [string]$FixMode = 'yes',
    [string]$DiscoveryMode = 'full',
    # Internal mode
    [switch]$Internal,
    [string]$InternalRepoPath,
    [string]$InternalModel,
    [string]$InternalOutputPath
)

$ErrorActionPreference = "Stop"

# ── Import shared module ─────────────────────────────────────────────
$sharedModule = Join-Path $PSScriptRoot "..\shared\MonkeyCommon.psm1"
if (-not (Test-Path $sharedModule)) {
    throw "Shared module not found at $sharedModule. Ensure monkey-army/shared/ exists."
}
Import-Module $sharedModule -Force

# ── Constants ────────────────────────────────────────────────────────
$MONKEY_NAME    = "Curious George"
$MONKEY_EMOJI   = "🐵"
$MONKEY_VERSION = "1.0"
$MONKEY_TAGLINE = "The Deep Auditor"
$MONKEY_PREFIX  = "curious-george"
$OUTPUT_DIR     = ".monkey-output"

# ── Resolve working paths ────────────────────────────────────────────
function Resolve-Environment {
    if ($Internal) {
        if (-not $InternalRepoPath -or -not (Test-Path $InternalRepoPath)) {
            throw "-Internal requires a valid -InternalRepoPath."
        }
        return @{
            WorkDir    = $InternalRepoPath
            Model      = $InternalModel
            OutputPath = if ($InternalOutputPath) { $InternalOutputPath } else {
                $p = Join-Path $InternalRepoPath $OUTPUT_DIR
                if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory -Force | Out-Null }
                $p
            }
            Branch     = $null  # orchestrator manages branches
        }
    }

    # Standalone mode — full setup
    Write-MonkeyBanner -Name $MONKEY_NAME -Emoji $MONKEY_EMOJI -Version $MONKEY_VERSION -Tagline $MONKEY_TAGLINE
    Test-Preflight

    $setup = Invoke-MonkeySetup `
        -RepoUrl $RepoUrl `
        -ClonePath $ClonePath `
        -RepoPath $RepoPath `
        -BaseBranch $BaseBranch `
        -UseBaseBranch:$UseBaseBranch `
        -BranchName $BranchName `
        -BranchPrefix $MONKEY_PREFIX `
        -OutputDirName $OUTPUT_DIR

    $selectedModel = Select-MonkeyModel -UserModel $Model -WorkingDirectory $setup.WorkDir
    Test-CopilotInRepo -WorkingDirectory $setup.WorkDir

    return @{
        WorkDir    = $setup.WorkDir
        Model      = $selectedModel
        OutputPath = $setup.OutputPath
        Branch     = $setup.Branch
    }
}

# ── Load & parse prompt ──────────────────────────────────────────────
function Get-GeorgePrompt {
    <#
    .SYNOPSIS
        Extracts prompt code block from the markdown file, prepends pre-answered
        setup questions so George runs non-interactively.
    #>
    Write-Phase "PHASE 1" "Loading prompt"

    $promptFile = Join-Path $PSScriptRoot "..\prompts\curious-george-prompt.md"
    if (-not (Test-Path $promptFile)) {
        throw "Prompt file not found: $promptFile"
    }

    $rawContent = Get-Content $promptFile -Raw -Encoding UTF8
    Write-Step "Read prompt file ($((Get-Item $promptFile).Length) bytes)" "OK"

    # Extract the code block content after the --- separator
    # The prompt is inside ```text ... ``` after the --- line
    $promptText = $null
    if ($rawContent -match '(?s)---\s*\r?\n\s*```text\s*\r?\n(.+?)```') {
        $promptText = $Matches[1].Trim()
    }
    elseif ($rawContent -match '(?s)---\s*\r?\n\s*```\s*\r?\n(.+?)```') {
        $promptText = $Matches[1].Trim()
    }

    if (-not $promptText) {
        throw "Could not extract prompt text from $promptFile. Expected a code block after --- separator."
    }

    Write-Step "Extracted prompt ($($promptText.Length) chars)" "OK"

    # Pre-answer the 7 setup questions
    $focusDisplay = if ($FocusArea) { $FocusArea } else { "all domains" }
    $preamble = @"
Here are my answers to your setup questions:
1. Questions per domain: $QuestionsPerDomain
2. Focus area: $focusDisplay
3. Difficulty: $Difficulty
4. Max consecutive covered before skip: $MaxSkip
5. Auto-fix gaps: $FixMode
6. Discovery mode: $DiscoveryMode
7. go

Now run the full autonomous loop. Do NOT ask any more questions.
Do NOT commit any changes - only edit files.

"@

    $statusBlock = @"

IMPORTANT: At the very end of your output, include this status block:
MONKEY_STATUS: SUCCESS or PARTIAL or FAILED
DOCS_CREATED: [number]
DOCS_UPDATED: [number]
QUESTIONS_ASKED: [number]
GAPS_FOUND: [number]
GAPS_FIXED: [number]
"@

    $fullPrompt = $preamble + $promptText + $statusBlock
    Write-Step "Built full prompt ($($fullPrompt.Length) chars) with pre-answered config" "OK"

    return $fullPrompt
}

# ── Parse git changes ────────────────────────────────────────────────
function Get-GitChangeSummary {
    param([string]$WorkDir)
    Push-Location $WorkDir
    try {
        $created   = @(& git --no-pager diff --name-only --diff-filter=A HEAD 2>$null)
        $modified  = @(& git --no-pager diff --name-only --diff-filter=M HEAD 2>$null)
        $untracked = @(& git --no-pager ls-files --others --exclude-standard 2>$null)
        return @{
            Created = $created.Count + $untracked.Count; Modified = $modified.Count
            TotalFiles = $created.Count + $modified.Count + $untracked.Count
        }
    } finally { Pop-Location }
}

# ══════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════

$startTime = Get-Date

try {
    # ── Phase 1: Setup ───────────────────────────────────────────────
    if (-not $Internal) {
        Write-Phase "PHASE 0" "Setup"
    }

    $env = Resolve-Environment
    $workDir    = $env.WorkDir
    $model      = $env.Model
    $outputPath = $env.OutputPath
    $branch     = $env.Branch

    # ── Phase 2: Load prompt ─────────────────────────────────────────
    $fullPrompt = Get-GeorgePrompt

    # Save prompt for debugging
    $promptSavePath = Join-Path $outputPath "george-prompt.txt"
    $fullPrompt | Set-Content $promptSavePath -Encoding UTF8
    Write-Step "Prompt saved to $promptSavePath" "OK"

    # ── Phase 3: Execute agent ───────────────────────────────────────
    Write-Phase "PHASE 2" "Executing Curious George agent (timeout: $($Timeout)s)"
    Write-Step "Model: $(if ($model) { $model } else { '(default)' })" "INFO"
    Write-Step "Config: $QuestionsPerDomain Qs/domain, difficulty=$Difficulty, discovery=$DiscoveryMode" "INFO"

    $sharePath = Join-Path $outputPath "george-share.txt"

    $agentResult = Start-AgentMonkey `
        -PromptText $fullPrompt `
        -WorkingDirectory $workDir `
        -ModelName $model `
        -Timeout $Timeout `
        -SharePath $sharePath

    # Save raw output
    $outputSavePath = Join-Path $outputPath "george-output.txt"
    if ($agentResult.Output) {
        $agentResult.Output | Set-Content $outputSavePath -Encoding UTF8
    }

    # ── Phase 4: Parse results ───────────────────────────────────────
    Write-Phase "PHASE 3" "Parsing results"

    $agentStatus = Read-AgentStatus -Output $agentResult.Output
    $gitChanges  = Get-GitChangeSummary -WorkDir $workDir

    $exitStatus = 'SUCCESS'
    $errors = @()

    if (-not $agentResult.Success) {
        $exitStatus = 'FAILED'
        $errors += "Agent did not complete successfully"
    }
    elseif ($agentStatus -and $agentStatus.Status) {
        $exitStatus = $agentStatus.Status
    }
    elseif (-not $agentStatus) {
        $exitStatus = 'PARTIAL'
        $errors += "No MONKEY_STATUS block found in output"
    }

    $questionsAsked = if ($agentStatus -and $agentStatus.QuestionsAsked) { $agentStatus.QuestionsAsked } else { 0 }
    $gapsFound      = if ($agentStatus -and $agentStatus.GapsFound) { $agentStatus.GapsFound } else { 0 }
    $gapsFixed      = if ($agentStatus -and $agentStatus.GapsFixed) { $agentStatus.GapsFixed } else { 0 }
    $docsCreated    = if ($agentStatus -and $agentStatus.DocsCreated) { $agentStatus.DocsCreated } else { 0 }
    $docsUpdated    = if ($agentStatus -and $agentStatus.DocsUpdated) { $agentStatus.DocsUpdated } else { 0 }

    # ── Phase 5: Report ──────────────────────────────────────────────
    Write-Phase "PHASE 4" "Summary"

    $duration = (Get-Date) - $startTime

    Write-Host ""
    Write-Host "  $MONKEY_EMOJI CURIOUS GEORGE RESULTS" -ForegroundColor Cyan
    Write-Host "  ════════════════════════════════════════" -ForegroundColor DarkCyan
    Write-Host "  Status:           $exitStatus" -ForegroundColor $(
        switch ($exitStatus) { 'SUCCESS' { 'Green' } 'PARTIAL' { 'Yellow' } default { 'Red' } }
    )
    Write-Host "  Questions asked:  $questionsAsked" -ForegroundColor White
    Write-Host "  Gaps found:       $gapsFound" -ForegroundColor $(if ($gapsFound -gt 0) { 'Yellow' } else { 'Green' })
    Write-Host "  Gaps fixed:       $gapsFixed" -ForegroundColor $(if ($gapsFixed -gt 0) { 'Green' } else { 'DarkGray' })
    Write-Host "  Docs created:     $docsCreated" -ForegroundColor White
    Write-Host "  Docs updated:     $docsUpdated" -ForegroundColor White
    Write-Host "  Files changed:    $($gitChanges.TotalFiles)" -ForegroundColor White
    Write-Host "  Agent duration:   $($agentResult.Duration.ToString('hh\:mm\:ss'))" -ForegroundColor DarkGray
    Write-Host "  Total duration:   $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor DarkGray
    Write-Host "  ════════════════════════════════════════" -ForegroundColor DarkCyan

    if ($errors.Count -gt 0) {
        foreach ($err in $errors) {
            Write-Host "  ⚠️  $err" -ForegroundColor Yellow
        }
    }

    # Save summary JSON
    $summary = @{
        MonkeyName      = $MONKEY_NAME
        ExitStatus      = $exitStatus
        QuestionsAsked  = $questionsAsked
        GapsFound       = $gapsFound
        GapsFixed       = $gapsFixed
        DocsCreated     = $docsCreated
        DocsUpdated     = $docsUpdated
        FilesChanged    = $gitChanges.TotalFiles
        Model           = if ($model) { $model } else { "(default)" }
        Difficulty      = $Difficulty
        DiscoveryMode   = $DiscoveryMode
        FocusArea       = if ($FocusArea) { $FocusArea } else { "all" }
        Duration        = $duration.ToString('hh\:mm\:ss')
        AgentDuration   = $agentResult.Duration.ToString('hh\:mm\:ss')
    }
    $summary | ConvertTo-Json -Depth 3 | Set-Content (Join-Path $outputPath "summary.json") -Encoding UTF8

    # ── Phase 6: Commit (standalone only) ────────────────────────────
    if (-not $Internal -and ($Commit -or $DryRun)) {
        Write-Phase "PHASE 5" "Commit"
        Invoke-MonkeyCommit `
            -WorkingDirectory $workDir `
            -OutputDirName $OUTPUT_DIR `
            -MonkeyName $MONKEY_NAME `
            -MonkeyEmoji $MONKEY_EMOJI `
            -BranchName $branch `
            -ModelName $model `
            -QuestionsAnswered $questionsAsked `
            -DryRun:$DryRun `
            -Commit:$Commit
    }

    # ── Return standardized result ───────────────────────────────────
    $result = New-MonkeyResult `
        -MonkeyName $MONKEY_NAME `
        -Duration $duration `
        -Model $model `
        -ExitStatus $exitStatus `
        -QuestionsAsked $questionsAsked `
        -QuestionsAnswered $questionsAsked `
        -DocRefsFound ($docsCreated + $docsUpdated) `
        -FilesCreated $gitChanges.Created `
        -FilesModified $gitChanges.Modified `
        -Errors $errors

    if (-not $Internal) {
        Write-Host ""
        Write-Host "  $MONKEY_EMOJI Curious George complete!" -ForegroundColor Green
    }

    return $result
}
catch {
    $duration = (Get-Date) - $startTime

    if (-not $Internal) {
        Write-Host "`n  ❌ FATAL: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  Stack: $($_.ScriptStackTrace)" -ForegroundColor DarkRed
    }

    return New-MonkeyResult `
        -MonkeyName $MONKEY_NAME `
        -Duration $duration `
        -Model $(if ($model) { $model } else { '' }) `
        -ExitStatus 'FAILED' `
        -Errors @($_.Exception.Message)
}
