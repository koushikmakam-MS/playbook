<#
.SYNOPSIS
    Playbook Runner 📋 — Knowledge Layer Generator (Monkey Army)

.DESCRIPTION
    Thin wrapper monkey that launches the Playbook v2.9 mega-prompt in agent mode.
    Runs as Phase 0 — BEFORE all other monkeys — to generate the knowledge layer
    (copilot-instructions.md, skills, workflow docs, discovery manifest).

    Two execution modes:
    - Standalone: handles own setup, branch, model selection, and commit
    - Internal (-Internal): orchestrator provides everything; returns result only

.PARAMETER RepoUrl
    Git repository URL to clone.
.PARAMETER ClonePath
    Directory to clone into. Default: .\monkey-workspace
.PARAMETER RepoPath
    Path to an existing local repository (skip cloning).
.PARAMETER BaseBranch
    Branch to base work on. If omitted, you'll be prompted.
.PARAMETER UseBaseBranch
    Work directly on the base branch instead of creating a new one.
.PARAMETER BranchName
    Custom branch name. Default: playbook/<timestamp>
.PARAMETER Model
    Override Copilot model selection.
.PARAMETER Timeout
    Agent mode timeout in seconds. Default: 7200 (2 hours).
.PARAMETER DryRun
    Stage changes but don't commit.
.PARAMETER Commit
    Auto-commit changes after execution.
.PARAMETER Internal
    Internal mode — called by orchestrator. Skips setup/commit.
.PARAMETER InternalRepoPath
    Repo path when in internal mode.
.PARAMETER InternalModel
    Model name when in internal mode.
.PARAMETER InternalOutputPath
    Output directory when in internal mode.

.EXAMPLE
    .\playbook-runner.ps1 -RepoPath "C:\myrepo" -Commit -Model "claude-sonnet-4"

.EXAMPLE
    .\playbook-runner.ps1 -Internal -InternalRepoPath "C:\myrepo" -InternalModel "claude-sonnet-4" -InternalOutputPath "C:\myrepo\.monkey-output"
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
    [int]$Timeout = 7200,
    [switch]$DryRun,
    [switch]$Commit,
    [switch]$Internal,
    [string]$InternalRepoPath,
    [string]$InternalModel,
    [string]$InternalOutputPath
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ── Import shared modules ────────────────────────────────────────────
$sharedModule = Join-Path $PSScriptRoot "..\shared\MonkeyCommon.psm1"
if (-not (Test-Path $sharedModule)) {
    throw "Shared module not found at $sharedModule. Ensure monkey-army/shared/ exists."
}
Import-Module $sharedModule -Force

$gitModule = Join-Path $PSScriptRoot "..\shared\GitProviders.psm1"
if (Test-Path $gitModule) {
    Import-Module $gitModule -Force
}

# ── Constants ────────────────────────────────────────────────────────
$script:MONKEY_NAME    = "Playbook"
$script:MONKEY_EMOJI   = "📋"
$script:MONKEY_VERSION = "1.0.0"
$script:MONKEY_TAGLINE = "Knowledge Layer Generator"
$script:PROMPT_FILE    = "playbook-v2.9.txt"
$script:OUTPUT_DIR     = ".monkey-output"

# ── Banner ───────────────────────────────────────────────────────────
Write-MonkeyBanner -Name $script:MONKEY_NAME `
                   -Emoji $script:MONKEY_EMOJI `
                   -Version $script:MONKEY_VERSION `
                   -Tagline $script:MONKEY_TAGLINE

# ── Resolve mode ─────────────────────────────────────────────────────
$workDir    = $null
$modelName  = $null
$outputPath = $null
$setupInfo  = $null
$startTime  = Get-Date

if ($Internal) {
    # ── Internal mode: orchestrator provides everything ──────────────
    Write-Phase "MODE" "Internal (orchestrator-driven)"

    if (-not $InternalRepoPath -or -not (Test-Path $InternalRepoPath)) {
        throw "Internal mode requires a valid -InternalRepoPath. Got: '$InternalRepoPath'"
    }

    $workDir    = $InternalRepoPath
    $modelName  = $InternalModel
    $outputPath = if ($InternalOutputPath) { $InternalOutputPath } else { Join-Path $workDir $script:OUTPUT_DIR }

    Write-Step -Message "Repo: $workDir" -Status 'OK'
    Write-Step -Message "Model: $(if ($modelName) { $modelName } else { 'auto' })" -Status 'OK'
}
else {
    # ── Standalone mode: full setup ──────────────────────────────────
    Write-Phase "PHASE 1" "Setup"

    Test-Preflight

    $setupInfo = Invoke-MonkeySetup `
        -RepoUrl $RepoUrl `
        -ClonePath $ClonePath `
        -RepoPath $RepoPath `
        -BaseBranch $BaseBranch `
        -UseBaseBranch:$UseBaseBranch `
        -BranchName $BranchName `
        -BranchPrefix 'playbook' `
        -OutputDirName $script:OUTPUT_DIR

    $workDir    = $setupInfo.WorkDir
    $outputPath = $setupInfo.OutputPath

    $modelName = Select-MonkeyModel -UserModel $Model -WorkingDirectory $workDir
    Write-Step -Message "Model selected: $modelName" -Status 'OK'

    Test-CopilotInRepo -WorkingDirectory $workDir
}

# Ensure output directory exists
if (-not (Test-Path $outputPath)) {
    New-Item -Path $outputPath -ItemType Directory -Force | Out-Null
}

# ── Load playbook prompt ─────────────────────────────────────────────
Write-Phase "PHASE 2" "Load Playbook Prompt"

$promptPath = Join-Path $PSScriptRoot "..\prompts\$($script:PROMPT_FILE)"
if (-not (Test-Path $promptPath)) {
    throw "Playbook prompt not found at: $promptPath"
}

$playbookText = Get-Content -Path $promptPath -Raw -Encoding UTF8
$promptSizeKB = [math]::Round($playbookText.Length / 1024, 1)
Write-Step -Message "Loaded $($script:PROMPT_FILE) (${promptSizeKB}KB)" -Status 'OK'

# ── Build combined prompt with pre-answers ────────────────────────────
Write-Phase "PHASE 3" "Prepare Agent Prompt"

$preAnswers = @"
Here are my answers to your setup questions:
- Repository is already cloned at: $workDir
- I want you to run ALL phases (0-7)
- Generate complete knowledge layer
- Auto-fix all gaps
- Create all docs without asking

Now run the full playbook autonomously. Do NOT ask any more questions.

"@

$statusSuffix = @"

IMPORTANT: At the very end of your output, include this machine-readable status block:
MONKEY_STATUS: SUCCESS or PARTIAL or FAILED
DOCS_CREATED: [number]
DOCS_UPDATED: [number]
QUESTIONS_ASKED: 0
GAPS_FOUND: [number]
GAPS_FIXED: [number]
"@

$combinedPrompt = $preAnswers + $playbookText + $statusSuffix
Write-Step -Message "Combined prompt assembled ($([math]::Round($combinedPrompt.Length / 1024, 1))KB)" -Status 'OK'

# ── Snapshot git state before execution ───────────────────────────────
Push-Location $workDir
try {
    $preStatus = & git --no-pager status --porcelain 2>&1
}
finally {
    Pop-Location
}

# ── Execute agent ─────────────────────────────────────────────────────
Write-Phase "PHASE 4" "Execute Playbook Agent"
Write-Step -Message "Timeout: $Timeout seconds ($([math]::Round($Timeout / 3600, 1))h)" -Status 'INFO'
Write-Step -Message "Working directory: $workDir" -Status 'INFO'

$sharePath = Join-Path $outputPath "playbook-session.md"
$agentResult = Start-AgentMonkey `
    -PromptText $combinedPrompt `
    -WorkingDirectory $workDir `
    -ModelName $modelName `
    -Timeout $Timeout `
    -SharePath $sharePath

$duration = (Get-Date) - $startTime

# ── Parse results ─────────────────────────────────────────────────────
Write-Phase "PHASE 5" "Parse Results"

$agentStatus = Read-AgentStatus -Output $agentResult.Output
$exitStatus  = 'FAILED'
$docsCreated = 0
$docsUpdated = 0
$gapsFound   = 0
$gapsFixed   = 0

if ($agentStatus) {
    $exitStatus  = $agentStatus.Status
    $docsCreated = [int]$agentStatus.DocsCreated
    $docsUpdated = [int]$agentStatus.DocsUpdated
    $gapsFound   = [int]$agentStatus.GapsFound
    $gapsFixed   = [int]$agentStatus.GapsFixed
    Write-Step -Message "Agent status: $exitStatus" -Status 'OK'
}
elseif ($agentResult.Success) {
    $exitStatus = 'PARTIAL'
    Write-Step -Message "Agent completed but no status block found" -Status 'WARN'
}
else {
    Write-Step -Message "Agent failed: $($agentResult.Error)" -Status 'ERROR'
}

# Count file changes
Push-Location $workDir
try {
    $postStatus    = & git --no-pager status --porcelain 2>&1
    $filesCreated  = @($postStatus | Where-Object { $_ -match '^\?\?' -and $_ -notmatch [regex]::Escape($script:OUTPUT_DIR) }).Count
    $filesModified = @($postStatus | Where-Object { $_ -and $_ -notmatch '^\?\?' -and $_ -notmatch [regex]::Escape($script:OUTPUT_DIR) }).Count
}
finally {
    Pop-Location
}

Write-Step -Message "Files created: $filesCreated | Files modified: $filesModified" -Status 'OK'
Write-Step -Message "Docs created: $docsCreated | Docs updated: $docsUpdated" -Status 'OK'
Write-Step -Message "Gaps found: $gapsFound | Gaps fixed: $gapsFixed" -Status 'OK'

# ── Summary ───────────────────────────────────────────────────────────
Write-MonkeySummary -Stats @{
    "Exit Status"    = $exitStatus
    "Duration"       = $duration.ToString("hh\:mm\:ss")
    "Model"          = if ($modelName) { $modelName } else { "auto" }
    "Files Created"  = $filesCreated
    "Files Modified" = $filesModified
    "Docs Created"   = $docsCreated
    "Docs Updated"   = $docsUpdated
    "Gaps Found"     = $gapsFound
    "Gaps Fixed"     = $gapsFixed
} -Emoji $script:MONKEY_EMOJI

# ── Commit (standalone only) ─────────────────────────────────────────
if (-not $Internal) {
    Invoke-MonkeyCommit `
        -WorkingDirectory $workDir `
        -OutputDirName $script:OUTPUT_DIR `
        -MonkeyName $script:MONKEY_NAME `
        -MonkeyEmoji $script:MONKEY_EMOJI `
        -BranchName $(if ($setupInfo) { $setupInfo.Branch } else { '' }) `
        -ModelName $modelName `
        -QuestionsAnswered ($docsCreated + $docsUpdated) `
        -DryRun:$DryRun `
        -Commit:$Commit
}

# ── Return standardized result ────────────────────────────────────────
$errors = @()
if (-not $agentResult.Success) { $errors += $agentResult.Error }

$result = New-MonkeyResult `
    -MonkeyName $script:MONKEY_NAME `
    -Duration $duration `
    -Model $modelName `
    -ExitStatus $exitStatus `
    -QuestionsAsked 0 `
    -QuestionsAnswered ($docsCreated + $docsUpdated) `
    -DocRefsFound $gapsFound `
    -FilesCreated $filesCreated `
    -FilesModified $filesModified `
    -DocsGroundedPct $(if ($gapsFound -gt 0) { [math]::Round(($gapsFixed / $gapsFound) * 100, 1) } else { 100.0 }) `
    -RetryCount 0 `
    -Errors $errors

return $result
