<#
.SYNOPSIS
    Run-Player.ps1 — Unified Orchestrator for the Monkey Army 🐒
    Single entry point that runs all monkeys in sequence, owns git lifecycle,
    and produces a unified report.

.DESCRIPTION
    Collects all inputs upfront via the wizard (Get-ArmyConfig), then:
    1. Preflight checks
    2. Repo setup (clone/branch)
    3. Model selection
    4. Run each monkey in phase order
    5. Collect standardized results
    6. Quality gate evaluation
    7. Heal mode (re-run failed monkeys with escalated model)
    8. Commit all changes
    9. Create PR (if requested)
    10. Print unified report

.PARAMETER RepoUrl
    Git repo URL to clone.
.PARAMETER RepoPath
    Path to an already-cloned local repo.
.PARAMETER Pack
    Monkey pack preset: audit, security, docs, full, autonomous, quick.
.PARAMETER Monkeys
    Comma-separated list of monkey IDs for custom selection.
.PARAMETER NonInteractive
    Skip all prompts, use defaults + explicit params.
.PARAMETER HealMode
    Re-run failed monkeys with an escalated model.

.EXAMPLE
    .\Run-Player.ps1 -RepoPath "C:\myrepo" -Pack audit -CommitMode commit
.EXAMPLE
    .\Run-Player.ps1 -RepoUrl "https://github.com/org/repo.git" -Pack full
.EXAMPLE
    .\Run-Player.ps1 -RepoPath "C:\myrepo" -Monkeys rafiki,abu -NonInteractive -CommitMode dry-run
#>

[CmdletBinding()]
param(
    [string]$RepoUrl,
    [string]$RepoPath,
    [string]$ClonePath,
    [string]$BaseBranch,
    [string]$BranchName,
    [switch]$UseBaseBranch,
    [string]$Model,
    [string]$Pack,
    [string[]]$Monkeys,
    [string]$CommitMode,
    [switch]$CreatePR,
    [string]$GitProvider,
    [int]$QuestionsPerEntry,
    [int]$QuestionsPerGap,
    [int]$QuestionsPerFile,
    # George-specific
    [int]$GeorgeQuestionsPerDomain,
    [string]$GeorgeFocusArea,
    [string]$GeorgeDifficulty,
    [int]$GeorgeMaxSkip,
    [string]$GeorgeFixMode,
    [string]$GeorgeDiscoveryMode,
    # Behavior
    [switch]$NonInteractive,
    [switch]$HealMode,
    [int]$MaxRetries = 3,
    [int]$RetryBaseDelay = 30,
    [int]$CallTimeout = 300,
    [switch]$ShowVerbose,
    [switch]$ForcePlaybook,      # Re-run playbook even if knowledge layer exists
    [string[]]$TargetAgents,     # AI agents to score for (copilot, cursor, claude, etc.)
    [int]$BatchSize = 10,        # Questions per answer batch (default 10, 0 = single mode)
    [int]$MaxQuestions = 500,     # Cap total questions per monkey (0 = no cap)
    [switch]$Incremental,        # Only process changed files
    [string]$Since,              # Git ref or date for incremental mode
    [switch]$Resume,             # Resume from last checkpoint
    [switch]$CleanStart,         # Purge all checkpoints before running
    [switch]$ParallelGen,        # Run question generation for all monkeys in parallel
    [int]$MaxParallelJobs = 3    # Max concurrent gen jobs when -ParallelGen is set
)

$ErrorActionPreference = "Stop"

# ── Import shared modules ──────────────────────────────────────────
Import-Module (Join-Path $PSScriptRoot "shared\MonkeyCommon.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "shared\GitProviders.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "shared\DocHealthScorer.psm1") -Force

# ── Playbook skip detection ────────────────────────────────────────

function Test-PlaybookComplete {
    <#
    .SYNOPSIS
        Detects whether the Playbook knowledge layer has already been generated.
        Returns a hashtable with detection results.
    #>
    param([Parameter(Mandatory)][string]$WorkingDirectory)

    $signals = @{
        HasCopilotInstructions = $false
        HasDiscoveryManifest   = $false
        HasWorkflowDocs        = $false
        HasSkills              = $false
        HasPlaybookCommit      = $false
        Score                  = 0
        Details                = @()
    }

    # Signal 1: .github/copilot-instructions.md exists
    $instrPath = Join-Path $WorkingDirectory ".github\copilot-instructions.md"
    if (Test-Path $instrPath) {
        $size = (Get-Item $instrPath).Length
        if ($size -gt 500) {
            $signals.HasCopilotInstructions = $true
            $signals.Score++
            $signals.Details += "copilot-instructions.md ($([Math]::Round($size/1KB,1))KB)"
        }
    }

    # Signal 2: Discovery manifest exists
    Push-Location $WorkingDirectory
    $manifests = @(& git ls-files 2>&1 | Where-Object { $_ -match 'Discovery_Manifest' -or $_ -match 'discovery.manifest' })
    Pop-Location
    if ($manifests.Count -gt 0) {
        $signals.HasDiscoveryManifest = $true
        $signals.Score++
        $signals.Details += "Discovery manifest found ($($manifests.Count) file(s))"
    }

    # Signal 3: Workflow docs directory with content
    Push-Location $WorkingDirectory
    $workflowDocs = @(& git ls-files 2>&1 | Where-Object {
        $_ -match 'docs/.+/workflows?/.+\.md$' -or
        $_ -match 'docs/[^/]+/.+\.md$' -or
        $_ -match 'docs/workflows?/.+\.md$'
    })
    Pop-Location
    if ($workflowDocs.Count -ge 3) {
        $signals.HasWorkflowDocs = $true
        $signals.Score++
        $signals.Details += "Workflow docs ($($workflowDocs.Count) files)"
    }

    # Signal 4: Skills directory
    $skillsDir = Join-Path $WorkingDirectory ".github\skills"
    if ((Test-Path $skillsDir) -and (Get-ChildItem $skillsDir -Recurse -Filter '*.md' -ErrorAction SilentlyContinue).Count -gt 0) {
        $signals.HasSkills = $true
        $signals.Score++
        $signals.Details += "Skills directory exists"
    }

    # Signal 5: Git log has playbook commit
    Push-Location $WorkingDirectory
    $playbookCommits = @(& git --no-pager log --oneline -20 2>&1 | Where-Object {
        $_ -match 'playbook|knowledge.layer|Phase [0-7]' 
    })
    Pop-Location
    if ($playbookCommits.Count -gt 0) {
        $signals.HasPlaybookCommit = $true
        $signals.Score++
        $signals.Details += "Playbook commit(s) in recent history"
    }

    # Verdict: score >= 3 means playbook was already run
    $signals.IsComplete = $signals.Score -ge 3

    return $signals
}

# ══════════════════════════════════════════════════════════════════
#  PHASE 0: INPUT WIZARD
# ══════════════════════════════════════════════════════════════════

$configParams = @{}
foreach ($key in $PSBoundParameters.Keys) {
    $configParams[$key] = $PSBoundParameters[$key]
}
$config = Get-ArmyConfig @configParams

# ══════════════════════════════════════════════════════════════════
#  PHASE 1: PREFLIGHT + REPO SETUP
# ══════════════════════════════════════════════════════════════════

$armyStart = Get-Date

Write-Host ""
Write-Host "  🐒🐒🐒 MONKEY ARMY DEPLOYING 🐒🐒🐒" -ForegroundColor Yellow
Write-Host ""

Test-Preflight

# ── Early checkpoint detection (before branch creation) ───────────
# Check if a checkpoint exists in the target repo so we can reuse its branch
$earlyRepoPath = if ($config.RepoPath) { $config.RepoPath } elseif ($config.ClonePath -and (Test-Path $config.ClonePath)) { $config.ClonePath } else { $null }
if ($earlyRepoPath -and -not $CleanStart) {
    $earlyCheckpointPath = Join-Path $earlyRepoPath ".monkey-output\run-checkpoint.json"
    if (Test-Path $earlyCheckpointPath) {
        try {
            $earlyCp = Get-Content $earlyCheckpointPath -Raw | ConvertFrom-Json
            $cpBranch = $earlyCp.branch
            $cpModel = $earlyCp.model
            $cpPack = $earlyCp.pack

            # Count monkey statuses (f05: separate completed vs skipped)
            $cpMonkeys = if ($earlyCp.monkeys -is [hashtable]) { $earlyCp.monkeys } else { $earlyCp.monkeys }
            $mProps = if ($cpMonkeys -is [hashtable]) { $cpMonkeys.Keys } else { $cpMonkeys.PSObject.Properties.Name }
            $completedCount = @($mProps | Where-Object {
                $s = if ($cpMonkeys -is [hashtable]) { $cpMonkeys[$_].status } else { $cpMonkeys.$_.status }
                $s -eq 'complete'
            }).Count
            $skippedCount = @($mProps | Where-Object {
                $s = if ($cpMonkeys -is [hashtable]) { $cpMonkeys[$_].status } else { $cpMonkeys.$_.status }
                $s -eq 'skipped'
            }).Count
            $doneCount = $completedCount + $skippedCount
            $totalCount = $mProps.Count

            Write-Host ""
            Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
            Write-Host "  ║       🔖 CHECKPOINT FOUND IN REPO                  ║" -ForegroundColor Cyan
            Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
            Write-Host "  Branch:  $cpBranch" -ForegroundColor DarkGray
            Write-Host "  Model:   $cpModel" -ForegroundColor DarkGray
            Write-Host "  Pack:    $cpPack" -ForegroundColor DarkGray
            Write-Host "  Progress: $doneCount/$totalCount done ($completedCount completed, $skippedCount skipped)" -ForegroundColor DarkGray
            Write-Host "  Tip: Use -Resume to continue from where you left off" -ForegroundColor DarkGray
            Write-Host ""

            $useCheckpoint = $false
            if ($Resume -or $NonInteractive) {
                # Auto-resume: adopt checkpoint branch
                $useCheckpoint = $true
                Write-Step "Resuming from checkpoint — using branch '$cpBranch'" "OK"
            }
            else {
                Write-Host "  Resume from this checkpoint?" -ForegroundColor Cyan
                Write-Host "    [R] Resume (use branch $cpBranch)  |  [F] Fresh start (new branch)" -ForegroundColor DarkGray
                $choice = Read-Host "  Choice (R/F, default=R)"
                $useCheckpoint = ($choice -notmatch '^[Ff]')
            }

            if ($useCheckpoint) {
                # Override branch to match checkpoint
                $config['BranchName'] = $cpBranch
                if (-not $Resume) { $Resume = $true }
                Write-Step "Branch (checkpoint): $cpBranch" "OK"
            }
        }
        catch {
            Write-Step "Checkpoint file found but unreadable — starting fresh" "WARN"
        }
    }
}

# Setup repo (clone/branch)
$setupParams = @{
    BranchPrefix  = "monkey-army"
    OutputDirName = ".monkey-output"
}
if ($config.RepoPath)      { $setupParams.RepoPath = $config.RepoPath }
if ($config.RepoUrl)       { $setupParams.RepoUrl = $config.RepoUrl }
if ($config.ClonePath)     { $setupParams.ClonePath = $config.ClonePath }
if ($config.BaseBranch)    { $setupParams.BaseBranch = $config.BaseBranch }
if ($config.UseBaseBranch) { $setupParams.UseBaseBranch = [switch]::new($true) }
if ($config.BranchName -or $config['BranchName'])    { $setupParams.BranchName = $config['BranchName'] ?? $config.BranchName }
if ($NonInteractive)       { $setupParams.NonInteractive = [switch]::new($true) }

$setup = Invoke-MonkeySetup @setupParams
$workDir    = $setup.WorkDir
$branchName = $setup.Branch
$outputRoot = $setup.OutputPath

# Model selection
$selectedModel = Select-MonkeyModel -UserModel $config['Model'] -WorkingDirectory $workDir -NonInteractive:$NonInteractive

# Pre-validation
Test-CopilotInRepo -WorkingDirectory $workDir -NonInteractive:$NonInteractive

# Git provider auth check
$authResult = Test-GitAuth -Provider $config.GitProvider -WorkingDirectory $workDir
if ($config.CreatePR -and -not $authResult.Authenticated) {
    Write-Step "Git auth warning: $($authResult.Error). PR creation may fail." "WARN"
}

# ══════════════════════════════════════════════════════════════════
#  PHASE 2: RUN MONKEYS IN ORDER
# ══════════════════════════════════════════════════════════════════

Write-Phase "ARMY" "Running $($config.OrderedMonkeys.Count) monkeys in sequence"

# ── Before score ──────────────────────────────────────────────────
Write-Phase "SCORE" "Measuring repo health (before)"
$beforeScore = Get-DocHealthScore -RepoPath $workDir -IncludeBonus -TargetAgents $config['TargetAgents']

$results = @{}
$resumedFromCheckpoint = $false
$monkeyScripts = @{
    'playbook'       = 'playbook-runner.ps1'
    'rafiki'         = 'rafiki.ps1'
    'abu'            = 'abu.ps1'
    'diddy-kong'     = 'diddy-kong.ps1'
    'king-louie'     = 'king-louie.ps1'
    'mojo-jojo'      = 'mojo-jojo.ps1'
    'donkey-kong'    = 'donkey-kong.ps1'
    'marcel'         = 'marcel.ps1'
    'curious-george' = 'curious-george.ps1'
}

# ── CleanStart: purge all checkpoints ─────────────────────────────
if ($CleanStart) {
    Write-Step "CleanStart: purging all checkpoints..." "INFO"
    $runCp = Join-Path $outputRoot "run-checkpoint.json"
    if (Test-Path $runCp) { Remove-Item $runCp -Force; Write-Step "  Removed run-checkpoint.json" "INFO" }
    Get-ChildItem -Path $outputRoot -Recurse -Filter "batch-checkpoint.json" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-Step "  Removed $($_.FullName)" "INFO"
    }
    Get-ChildItem -Path $outputRoot -Recurse -Filter "questions-checkpoint.json" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item $_.FullName -Force
        Write-Step "  Removed $($_.FullName)" "INFO"
    }
    Write-Step "All checkpoints purged — starting fresh" "OK"
}

# ── Checkpoint / Resume detection ─────────────────────────────────
$existingCheckpoint = Get-RunCheckpoint -OutputRoot $outputRoot
$skipMonkeys = @{}  # monkeyId → $true for monkeys to skip on resume

if ($existingCheckpoint) {
    Show-RunCheckpointSummary -Checkpoint $existingCheckpoint

    # Validate compatibility
    $compat = Test-RunCheckpointCompatible -Checkpoint $existingCheckpoint `
        -Model $selectedModel -Pack $config.Pack -BatchSize $BatchSize `
        -Branch $branchName -WorkDir $workDir

    if (-not $compat.Compatible) {
        Write-Host "  ⚠️  Checkpoint is NOT compatible with current settings:" -ForegroundColor Yellow
        foreach ($r in $compat.Reasons) { Write-Host "    → $r" -ForegroundColor Yellow }
        Write-Host ""
    }

    $shouldResume = $false
    if ($Resume) {
        # Auto-resume if -Resume switch and compatible
        if ($compat.Compatible) {
            $shouldResume = $true
            Write-Step "Auto-resuming from checkpoint (-Resume flag)" "OK"
        } else {
            Write-Step "Cannot auto-resume — checkpoint incompatible. Starting fresh." "WARN"
        }
    }
    elseif (-not $NonInteractive) {
        # Interactive prompt
        if ($compat.Compatible) {
            Write-Host "  Resume from this checkpoint?" -ForegroundColor Cyan
            Write-Host "    [R] Resume  |  [F] Fresh start" -ForegroundColor DarkGray
            $choice = Read-Host "  Choice (R/F)"
            $shouldResume = ($choice -match '^[Rr]')
        } else {
            Write-Host "  Checkpoint found but incompatible. Starting fresh." -ForegroundColor Yellow
            Write-Host "  Press Enter to continue or Ctrl+C to abort..." -ForegroundColor DarkGray
            Read-Host | Out-Null
        }
    }
    else {
        # NonInteractive without Resume — fresh start (safe default)
        Write-Step "Checkpoint found but -NonInteractive without -Resume. Starting fresh." "WARN"
    }

    if ($shouldResume) {
        $resumedFromCheckpoint = $true
        Write-Step "Resuming from checkpoint" "OK"

        # Reload before score if saved
        if ($existingCheckpoint.beforeScore) {
            $beforeScore = $existingCheckpoint.beforeScore
            Write-Step "Reusing saved before-score (grade: $($beforeScore.Grade))" "INFO"
        }

        # Mark completed monkeys for skip and restore their results
        $monkeyData = $existingCheckpoint.monkeys
        $monkeyProps = if ($monkeyData -is [hashtable]) { $monkeyData.Keys } else { $monkeyData.PSObject.Properties.Name }
        foreach ($mId in $monkeyProps) {
            $mState = if ($monkeyData -is [hashtable]) { $monkeyData[$mId] } else { $monkeyData.$mId }
            if ($mState.status -in @('complete', 'skipped') -and $mState.result) {
                $skipMonkeys[$mId] = $true
                # Restore result — convert PSCustomObject back to hashtable
                $restored = @{}
                foreach ($prop in $mState.result.PSObject.Properties) {
                    $restored[$prop.Name] = $prop.Value
                }
                $results[$mId] = $restored
            }
            elseif ($mState.status -eq 'skipped') {
                # Skipped without result (e.g., playbook skip) — still skip on resume
                $skipMonkeys[$mId] = $true
            }
            # in-progress and failed monkeys will be re-run (not skipped)
        }

        $skipCount = $skipMonkeys.Count
        $remainCount = $config.OrderedMonkeys.Count - $skipCount
        $completedLabel = @($skipMonkeys.Keys | Where-Object { $_ -in $config.OrderedMonkeys }) -join ", "
        Write-Step "Skipping $skipCount completed/skipped monkey(s) ($completedLabel), running $remainCount remaining" "INFO"
    }
    else {
        # Fresh start — remove old checkpoint
        Remove-RunCheckpoint -OutputRoot $outputRoot
    }
}

# ── Initialize checkpoint for this run ────────────────────────────
$runCheckpoint = @{
    startedAt   = (Get-Date).ToString('o')
    model       = $selectedModel
    pack        = $config.Pack
    batchSize   = $BatchSize
    branch      = $branchName
    repoPath    = $workDir
    beforeScore = $beforeScore
    monkeys     = @{}
}

# Pre-populate monkey states
foreach ($monkey in $config.OrderedMonkeys) {
    if ($skipMonkeys.ContainsKey($monkey.Id)) {
        $runCheckpoint.monkeys[$monkey.Id] = @{
            status      = 'complete'
            completedAt = $existingCheckpoint.monkeys.($monkey.Id).completedAt
            result      = $results[$monkey.Id]
        }
    } else {
        $runCheckpoint.monkeys[$monkey.Id] = @{ status = 'pending' }
    }
}
Save-RunCheckpoint -OutputRoot $outputRoot -CheckpointData $runCheckpoint

# ── Parallel Question Generation ──────────────────────────────────
# When -ParallelGen is set, run question gen for all prompt-mode monkeys
# in parallel using PS7 jobs, then feed pre-generated questions to the
# sequential answering loop.
$parallelGenResults = @{}  # monkeyId → questions array

if ($ParallelGen) {
    # Identify prompt-mode monkeys eligible for parallel gen (exclude agent-mode and already-completed)
    $genEligible = @($config.OrderedMonkeys | Where-Object {
        $_.Mode -eq 'prompt' -and
        -not $skipMonkeys.ContainsKey($_.Id)
    })

    if ($genEligible.Count -gt 1) {
        Write-Host ""
        Write-Host "  ══════════════════════════════════════════" -ForegroundColor Magenta
        Write-Host "  ⚡ PARALLEL QUESTION GENERATION" -ForegroundColor Magenta
        Write-Host "  ══════════════════════════════════════════" -ForegroundColor Magenta
        Write-Host "  Launching $($genEligible.Count) monkeys in parallel (max $MaxParallelJobs concurrent)..." -ForegroundColor Cyan

        $genStartTime = Get-Date
        $jobs = @{}
        $totalJobs = $genEligible.Count
        $completed = 0

        foreach ($monkey in $genEligible) {
            # Throttle: wait until a slot is free
            while ($jobs.Count -gt 0 -and ($jobs.Values | Where-Object { $_.Job.State -eq 'Running' }).Count -ge $MaxParallelJobs) {
                Start-Sleep -Seconds 3
                $nowComplete = @($jobs.Values | Where-Object { $_.Job.State -ne 'Running' }).Count
                if ($nowComplete -gt $completed) {
                    $completed = $nowComplete
                    $elapsed = ((Get-Date) - $genStartTime).ToString('mm\:ss')
                    Write-Host "    ⏱️  $completed/$totalJobs gen jobs complete ($elapsed elapsed)" -ForegroundColor DarkGray
                }
            }
            $mid = $monkey.Id
            $mScript = Join-Path $PSScriptRoot "monkey-army" $monkeyScripts[$mid]

            if (-not (Test-Path $mScript)) { continue }

            # Create per-monkey output dir
            $mOutDir = Join-Path $outputRoot $mid
            New-Item -ItemType Directory -Path $mOutDir -Force | Out-Null
            New-Item -ItemType Directory -Path (Join-Path $mOutDir "session-logs") -Force | Out-Null

            # Build GenOnly params
            $gParams = @{
                Internal           = $true
                InternalRepoPath   = $workDir
                InternalModel      = $selectedModel
                InternalOutputPath = $mOutDir
                GenOnly            = $true
            }

            # Add monkey-specific params
            if ($BatchSize -and $mid -notin @('playbook', 'curious-george')) { $gParams.BatchSize = $BatchSize }
            if ($config.MaxQuestions) { $gParams.MaxQuestions = $config.MaxQuestions }
            if ($Incremental) { $gParams.Incremental = $true; if ($Since) { $gParams.Since = $Since } }

            switch ($mid) {
                'rafiki'     { $gParams.QuestionsPerEntry = $config.QuestionsPerEntry; if ($ShowVerbose) { $gParams.ShowVerbose = $true } }
                'abu'        { $gParams.QuestionsPerGap = $config.QuestionsPerGap; if ($ShowVerbose) { $gParams.ShowVerbose = $true } }
                'mojo-jojo'  { $gParams.QuestionsPerFile = $config.QuestionsPerFile; if ($ShowVerbose) { $gParams.ShowVerbose = $true } }
                'diddy-kong' { if ($config.QuestionsPerEntry) { $gParams.QuestionsPerFinding = [Math]::Max(3, [int]($config.QuestionsPerEntry / 3)) }; if ($ShowVerbose) { $gParams.ShowVerbose = $true } }
                default      { if ($ShowVerbose) { $gParams.ShowVerbose = $true } }
            }

            Write-Host "    🚀 $($monkey.Emoji) $($monkey.Name) — launching gen job..." -ForegroundColor DarkCyan

            # Launch as PS7 job
            $job = Start-Job -ScriptBlock {
                param($ScriptPath, $Params)
                & $ScriptPath @Params
            } -ArgumentList $mScript, $gParams

            $jobs[$mid] = @{ Job = $job; Monkey = $monkey }
        }

        # Wait for remaining jobs with progress reporting
        Write-Host ""

        while ($jobs.Values | Where-Object { $_.Job.State -eq 'Running' }) {
            Start-Sleep -Seconds 5
            $nowComplete = @($jobs.Values | Where-Object { $_.Job.State -ne 'Running' }).Count
            if ($nowComplete -gt $completed) {
                $completed = $nowComplete
                $elapsed = ((Get-Date) - $genStartTime).ToString('mm\:ss')
                Write-Host "    ⏱️  $completed/$totalJobs gen jobs complete ($elapsed elapsed)" -ForegroundColor DarkGray
            }
        }

        # Collect results
        $genSuccessCount = 0
        $genFailCount = 0

        foreach ($mid in $jobs.Keys) {
            $jobInfo = $jobs[$mid]
            try {
                $genResult = Receive-Job -Job $jobInfo.Job -ErrorAction Stop
                Remove-Job -Job $jobInfo.Job -Force

                if ($genResult -and $genResult.Status -eq 'gen-complete' -and $genResult.Questions -and $genResult.Questions.Count -gt 0) {
                    $parallelGenResults[$mid] = $genResult.Questions
                    $genSuccessCount++
                    Write-Host "    ✅ $($jobInfo.Monkey.Emoji) $($jobInfo.Monkey.Name): $($genResult.Count) questions generated" -ForegroundColor Green
                } else {
                    $genFailCount++
                    Write-Host "    ⚠️  $($jobInfo.Monkey.Emoji) $($jobInfo.Monkey.Name): gen returned no questions — will run sequentially" -ForegroundColor Yellow
                }
            }
            catch {
                Remove-Job -Job $jobInfo.Job -Force -ErrorAction SilentlyContinue
                $genFailCount++
                Write-Host "    ❌ $($jobInfo.Monkey.Emoji) $($jobInfo.Monkey.Name): gen failed — $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "       Will fall back to sequential gen+answer" -ForegroundColor DarkYellow
            }
        }

        $genElapsed = ((Get-Date) - $genStartTime).ToString('mm\:ss')
        $totalQs = ($parallelGenResults.Values | ForEach-Object { $_.Count } | Measure-Object -Sum).Sum
        Write-Host ""
        Write-Host "  ⚡ Parallel gen complete: $genSuccessCount succeeded, $genFailCount failed ($totalQs total questions in $genElapsed)" -ForegroundColor Magenta
        Write-Host ""

        # Save genPhase in checkpoint
        $runCheckpoint.genPhase = @{
            status    = 'complete'
            elapsed   = $genElapsed
            monkeys   = @{}
        }
        foreach ($mid in $parallelGenResults.Keys) {
            $runCheckpoint.genPhase.monkeys[$mid] = @{ questionCount = $parallelGenResults[$mid].Count }
        }
        Save-RunCheckpoint -OutputRoot $outputRoot -CheckpointData $runCheckpoint
    }
    else {
        Write-Step "ParallelGen: only $($genEligible.Count) eligible monkey(s) — using sequential mode" "INFO"
    }
}

foreach ($monkey in $config.OrderedMonkeys) {
    $monkeyId = $monkey.Id
    $monkeyScript = Join-Path $PSScriptRoot "monkey-army" $monkeyScripts[$monkeyId]

    # ── Skip if already completed in checkpoint ──
    if ($skipMonkeys.ContainsKey($monkeyId)) {
        Write-Host ""
        Write-Host "  ══════════════════════════════════════════" -ForegroundColor DarkCyan
        Write-Host "  Phase $($monkey.Phase): $($monkey.Emoji) $($monkey.Name) — RESUMED (skipped)" -ForegroundColor DarkGreen
        Write-Host "  ══════════════════════════════════════════" -ForegroundColor DarkCyan
        $r = $results[$monkeyId]
        if ($r) {
            Write-Host "  → Previously: $($r.ExitStatus) ($($r.QuestionsAnswered)/$($r.QuestionsAsked) answered)" -ForegroundColor DarkGray
        }
        continue
    }

    if (-not (Test-Path $monkeyScript)) {
        Write-Step "$($monkey.Emoji) $($monkey.Name) — script not found, SKIPPING" "WARN"
        $results[$monkeyId] = New-MonkeyResult -MonkeyName $monkey.Name -ExitStatus 'SKIPPED' `
            -Errors @("Script not found: $monkeyScript")
        $runCheckpoint.monkeys[$monkeyId] = @{ status = 'skipped'; completedAt = (Get-Date).ToString('o') }
        Save-RunCheckpoint -OutputRoot $outputRoot -CheckpointData $runCheckpoint
        continue
    }

    # ── Playbook skip detection ──
    if ($monkeyId -eq 'playbook' -and -not $ForcePlaybook) {
        $playbookCheck = Test-PlaybookComplete -WorkingDirectory $workDir
        if ($playbookCheck.IsComplete) {
            Write-Host ""
            Write-Host "  ══════════════════════════════════════════" -ForegroundColor DarkCyan
            Write-Host "  Phase $($monkey.Phase): $($monkey.Emoji) $($monkey.Name) — ALREADY COMPLETE" -ForegroundColor Yellow
            Write-Host "  ══════════════════════════════════════════" -ForegroundColor DarkCyan
            Write-Host "  Knowledge layer detected (score $($playbookCheck.Score)/5):" -ForegroundColor DarkGray
            foreach ($d in $playbookCheck.Details) {
                Write-Host "    ✅ $d" -ForegroundColor Green
            }
            Write-Host "  Use -ForcePlaybook to re-run anyway." -ForegroundColor DarkGray
            $results[$monkeyId] = New-MonkeyResult -MonkeyName $monkey.Name -ExitStatus 'SKIPPED' `
                -Errors @("Knowledge layer already exists (score $($playbookCheck.Score)/5)")
            $runCheckpoint.monkeys[$monkeyId] = @{ status = 'skipped'; completedAt = (Get-Date).ToString('o') }
            Save-RunCheckpoint -OutputRoot $outputRoot -CheckpointData $runCheckpoint
            continue
        }
        elseif ($playbookCheck.Score -gt 0) {
            Write-Step "Partial knowledge layer detected (score $($playbookCheck.Score)/5) — running playbook to complete it" "WARN"
            foreach ($d in $playbookCheck.Details) {
                Write-Host "    ⚠️ $d" -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""
    Write-Host "  ══════════════════════════════════════════" -ForegroundColor DarkCyan
    Write-Host "  Phase $($monkey.Phase): $($monkey.Emoji) $($monkey.Name) [$($monkey.Mode) mode]" -ForegroundColor Cyan
    Write-Host "  ══════════════════════════════════════════" -ForegroundColor DarkCyan

    # Create per-monkey output dir
    $monkeyOutputDir = Join-Path $outputRoot $monkeyId
    New-Item -ItemType Directory -Path $monkeyOutputDir -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $monkeyOutputDir "session-logs") -Force | Out-Null

    # Build internal params (common to all monkeys)
    $monkeyParams = @{
        Internal           = $true
        InternalRepoPath   = $workDir
        InternalModel      = $selectedModel
        InternalOutputPath = $monkeyOutputDir
    }

    # BatchSize is common to all prompt-mode monkeys
    if ($BatchSize -and $monkeyId -notin @('playbook', 'curious-george')) {
        $monkeyParams.BatchSize = $BatchSize
    }

    # MaxQuestions cap is common to all prompt-mode monkeys
    if ($config.MaxQuestions -and $monkeyId -notin @('playbook', 'curious-george')) {
        $monkeyParams.MaxQuestions = $config.MaxQuestions
    }

    # Incremental mode is common to all prompt-mode monkeys
    if ($Incremental -and $monkeyId -notin @('playbook', 'curious-george')) {
        $monkeyParams.Incremental = $true
        if ($Since) { $monkeyParams.Since = $Since }
    }

    # Add monkey-specific params
    switch ($monkeyId) {
        'rafiki' {
            $monkeyParams.QuestionsPerEntry = $config.QuestionsPerEntry
            $monkeyParams.MaxRetries = $MaxRetries
            $monkeyParams.RetryBaseDelay = $RetryBaseDelay
            $monkeyParams.CallTimeout = $CallTimeout
            if ($ShowVerbose) { $monkeyParams.ShowVerbose = $true }
        }
        'abu' {
            $monkeyParams.QuestionsPerGap = $config.QuestionsPerGap
            $monkeyParams.MaxRetries = $MaxRetries
            $monkeyParams.RetryBaseDelay = $RetryBaseDelay
            $monkeyParams.CallTimeout = $CallTimeout
            if ($ShowVerbose) { $monkeyParams.ShowVerbose = $true }
        }
        'mojo-jojo' {
            $monkeyParams.QuestionsPerFile = $config.QuestionsPerFile
            $monkeyParams.MaxRetries = $MaxRetries
            $monkeyParams.RetryBaseDelay = $RetryBaseDelay
            $monkeyParams.CallTimeout = $CallTimeout
            if ($ShowVerbose) { $monkeyParams.ShowVerbose = $true }
        }
        'diddy-kong' {
            if ($config.QuestionsPerEntry) { $monkeyParams.QuestionsPerFinding = [Math]::Max(3, [int]($config.QuestionsPerEntry / 3)) }
            $monkeyParams.MaxRetries = $MaxRetries
            $monkeyParams.RetryBaseDelay = $RetryBaseDelay
            $monkeyParams.CallTimeout = $CallTimeout
            if ($ShowVerbose) { $monkeyParams.ShowVerbose = $true }
        }
        'king-louie' {
            $monkeyParams.MaxRetries = $MaxRetries
            $monkeyParams.RetryBaseDelay = $RetryBaseDelay
            $monkeyParams.CallTimeout = $CallTimeout
            if ($ShowVerbose) { $monkeyParams.ShowVerbose = $true }
        }
        'donkey-kong' {
            $monkeyParams.MaxRetries = $MaxRetries
            $monkeyParams.RetryBaseDelay = $RetryBaseDelay
            $monkeyParams.CallTimeout = $CallTimeout
            if ($ShowVerbose) { $monkeyParams.ShowVerbose = $true }
        }
        'marcel' {
            $monkeyParams.MaxRetries = $MaxRetries
            $monkeyParams.RetryBaseDelay = $RetryBaseDelay
            $monkeyParams.CallTimeout = $CallTimeout
            if ($ShowVerbose) { $monkeyParams.ShowVerbose = $true }
        }
        'playbook' {
            $monkeyParams.Timeout = 7200
        }
        'curious-george' {
            $monkeyParams.Timeout = 7200
            if ($config.GeorgeQuestionsPerDomain) { $monkeyParams.QuestionsPerDomain = $config.GeorgeQuestionsPerDomain }
            if ($config.GeorgeFocusArea)          { $monkeyParams.FocusArea = $config.GeorgeFocusArea }
            if ($config.GeorgeDifficulty)         { $monkeyParams.Difficulty = $config.GeorgeDifficulty }
            if ($config.GeorgeMaxSkip)            { $monkeyParams.MaxSkip = $config.GeorgeMaxSkip }
            if ($config.GeorgeFixMode)            { $monkeyParams.FixMode = $config.GeorgeFixMode }
            if ($config.GeorgeDiscoveryMode)      { $monkeyParams.DiscoveryMode = $config.GeorgeDiscoveryMode }
        }
    }

    # Pass pre-generated questions if available from parallel gen
    if ($parallelGenResults.ContainsKey($monkeyId) -and $parallelGenResults[$monkeyId].Count -gt 0) {
        $monkeyParams.PreGenQuestions = $parallelGenResults[$monkeyId]
        Write-Host "    ⚡ Using $($parallelGenResults[$monkeyId].Count) pre-generated questions from parallel gen" -ForegroundColor Magenta
    }

    # Run the monkey
    $monkeyStartTime = Get-Date

    # ── Mark in-progress in checkpoint ──
    $runCheckpoint.monkeys[$monkeyId] = @{ status = 'in-progress'; startedAt = (Get-Date).ToString('o') }
    Save-RunCheckpoint -OutputRoot $outputRoot -CheckpointData $runCheckpoint

    try {
        $result = & $monkeyScript @monkeyParams
        if (-not $result -or $result -isnot [hashtable]) {
            # Monkey didn't return a result — build one from what we know
            $result = New-MonkeyResult -MonkeyName $monkey.Name `
                -Duration ((Get-Date) - $monkeyStartTime) -Model $selectedModel -ExitStatus 'PARTIAL' `
                -Errors @("Monkey did not return a standardized result")
        }
        $results[$monkeyId] = $result
        $statusColor = switch ($result.ExitStatus) {
            'SUCCESS' { 'Green' }
            'PARTIAL' { 'Yellow' }
            'SKIPPED' { 'DarkGray' }
            default   { 'Red' }
        }
        Write-Host "  → $($monkey.Emoji) $($monkey.Name): $($result.ExitStatus) ($($result.QuestionsAnswered)/$($result.QuestionsAsked) answered, $($result.Duration))" -ForegroundColor $statusColor

        # ── Save checkpoint after monkey completes ──
        $cpStatus = if ($result.ExitStatus -eq 'FAILED') { 'failed' } else { 'complete' }
        $runCheckpoint.monkeys[$monkeyId] = @{
            status      = $cpStatus
            completedAt = (Get-Date).ToString('o')
            result      = $result
        }
        Save-RunCheckpoint -OutputRoot $outputRoot -CheckpointData $runCheckpoint
    }
    catch {
        Write-Host "  → $($monkey.Emoji) $($monkey.Name): FAILED — $($_.Exception.Message)" -ForegroundColor Red
        $results[$monkeyId] = New-MonkeyResult -MonkeyName $monkey.Name `
            -Duration ((Get-Date) - $monkeyStartTime) -Model $selectedModel -ExitStatus 'FAILED' `
            -Errors @($_.Exception.Message)

        # ── Save failed state in checkpoint ──
        $runCheckpoint.monkeys[$monkeyId] = @{
            status   = 'failed'
            failedAt = (Get-Date).ToString('o')
            error    = $_.Exception.Message
        }
        Save-RunCheckpoint -OutputRoot $outputRoot -CheckpointData $runCheckpoint
    }
}

# ══════════════════════════════════════════════════════════════════
#  PHASE 3: QUALITY GATE
# ══════════════════════════════════════════════════════════════════

Write-Phase "QUALITY GATE" "Evaluating results"

$totalAsked    = ($results.Values | Measure-Object -Property QuestionsAsked -Sum).Sum
$totalAnswered = ($results.Values | Measure-Object -Property QuestionsAnswered -Sum).Sum
$totalRetries  = ($results.Values | Measure-Object -Property RetryCount -Sum).Sum
$successCount  = @($results.Values | Where-Object { $_.ExitStatus -eq 'SUCCESS' }).Count
$failedCount   = @($results.Values | Where-Object { $_.ExitStatus -eq 'FAILED' }).Count
$partialCount  = @($results.Values | Where-Object { $_.ExitStatus -eq 'PARTIAL' }).Count
$skippedCount  = @($results.Values | Where-Object { $_.ExitStatus -eq 'SKIPPED' }).Count

# Check git changes
Push-Location $workDir
$gitChanges = & git --no-pager status --porcelain 2>&1
$changedFiles = @($gitChanges | Where-Object { $_ -and $_ -notmatch '\.monkey-output' }).Count
Pop-Location

$gatePass = $true
$gateReasons = @()

# Gate 1: At least one monkey succeeded
if ($successCount -eq 0 -and $partialCount -eq 0) {
    $gatePass = $false
    $gateReasons += "No monkeys succeeded"
}

# Gate 2: Answer rate > 50%
$answerRate = if ($totalAsked -gt 0) { [Math]::Round(($totalAnswered / $totalAsked) * 100, 1) } else { 0 }
if ($totalAsked -gt 0 -and $answerRate -lt 50) {
    $gatePass = $false
    $gateReasons += "Answer rate too low: $answerRate%"
}

# Gate 3: Some doc changes happened
if ($changedFiles -eq 0) {
    $gateReasons += "No file changes detected (docs may already be complete)"
}

$gateVerdict = if ($gatePass) { "PASS ✅" } else { "FAIL ❌" }
Write-Step "Quality gate: $gateVerdict" $(if ($gatePass) { "OK" } else { "ERROR" })
if ($gateReasons.Count -gt 0) {
    foreach ($r in $gateReasons) { Write-Step "  → $r" "WARN" }
}

# ══════════════════════════════════════════════════════════════════
#  PHASE 4: HEAL MODE (optional)
# ══════════════════════════════════════════════════════════════════

$healedMonkeys = @()
if ($HealMode -and $failedCount -gt 0) {
    Write-Phase "HEAL" "Re-running $failedCount failed monkey(s) with escalated model"

    # Escalate model
    $repoMeta = Get-RepoMetadata -WorkingDirectory $workDir
    $escalatedModels = Select-ModelForRepo -SizeTier $repoMeta.SizeTier -Mode 'agent'
    $healModel = if ($escalatedModels -and $escalatedModels.Count -gt 0) { $escalatedModels[0] } else { 'claude-opus-4.7' }
    Write-Step "Heal model: $healModel" "INFO"

    foreach ($monkeyId in $results.Keys) {
        if ($results[$monkeyId].ExitStatus -ne 'FAILED') { continue }

        $monkey = Get-MonkeyById -Id $monkeyId
        if (-not $monkey) { continue }

        $monkeyScript = Join-Path $PSScriptRoot "monkey-army" $monkeyScripts[$monkeyId]
        $monkeyOutputDir = Join-Path $outputRoot "$monkeyId-heal"
        New-Item -ItemType Directory -Path $monkeyOutputDir -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $monkeyOutputDir "session-logs") -Force | Out-Null

        Write-Step "Re-running $($monkey.Emoji) $($monkey.Name) with $healModel..." "INFO"

        $healParams = @{
            Internal           = $true
            InternalRepoPath   = $workDir
            InternalModel      = $healModel
            InternalOutputPath = $monkeyOutputDir
        }

        try {
            $healResult = & $monkeyScript @healParams
            if ($healResult -and $healResult.ExitStatus -ne 'FAILED') {
                $results[$monkeyId] = $healResult
                $healedMonkeys += $monkeyId
                Write-Step "$($monkey.Emoji) $($monkey.Name) healed: $($healResult.ExitStatus)" "OK"
            }
        }
        catch {
            Write-Step "$($monkey.Emoji) $($monkey.Name) heal failed: $($_.Exception.Message)" "ERROR"
        }
    }
}

# ══════════════════════════════════════════════════════════════════
#  PHASE 5: COMMIT / PUSH / PR
# ══════════════════════════════════════════════════════════════════

Write-Phase "COMMIT" "Staging and committing changes"

$commitSummary = @()
foreach ($m in $config.OrderedMonkeys) {
    $r = $results[$m.Id]
    if ($r) { $commitSummary += "  $($m.Emoji) $($m.Name): $($r.ExitStatus) ($($r.QuestionsAnswered) answered)" }
}

$totalFiles = 0
if ($config.CommitMode -ne 'stage') {
    $totalFiles = Invoke-MonkeyCommit -WorkingDirectory $workDir -OutputDirName ".monkey-output" `
        -MonkeyName "Monkey Army" -MonkeyEmoji "🐒" -BranchName $branchName `
        -ModelName $selectedModel -QuestionsAnswered $totalAnswered `
        -DryRun:($config.CommitMode -eq 'dry-run') -Commit:($config.CommitMode -eq 'commit')
}

# PR creation
$prResult = $null
if ($config.CreatePR -and $config.CommitMode -eq 'commit' -and -not $config.UseBaseBranch -and $totalFiles -gt 0) {
    Write-Phase "PR" "Creating pull request"

    $prBody = @"
## 🐒 Monkey Army Documentation Update

**Pack:** $($config.Pack)
**Monkeys run:** $($config.OrderedMonkeys.Count)
**Questions asked:** $totalAsked
**Questions answered:** $totalAnswered
**Files changed:** $totalFiles
**Quality gate:** $gateVerdict

### Results per monkey
$($commitSummary -join "`n")

### Heal mode
$(if ($healedMonkeys.Count -gt 0) { "Healed: $($healedMonkeys -join ', ')" } else { "N/A" })

---
*Auto-generated by Monkey Army 🐒*
"@

    $prResult = New-GitPullRequest -Provider $config.GitProvider -WorkingDirectory $workDir `
        -SourceBranch $branchName -TargetBranch $config.BaseBranch `
        -Title "docs: 🐒 Monkey Army documentation update" -Body $prBody

    if ($prResult.Created) {
        Write-Step "PR created: $($prResult.Url)" "OK"
    }
    else {
        Write-Step "PR creation failed: $($prResult.Error)" "WARN"
    }
}

# ══════════════════════════════════════════════════════════════════
#  PHASE 9: CLEANUP — Dedup, template check, orphan removal, index rebuild
# ══════════════════════════════════════════════════════════════════

Write-Phase "CLEANUP" "Post-run doc cleanup and quality pass"

# Take a pre-cleanup score to guard against regression
$preCleanupScore = Get-DocHealthScore -RepoPath $workDir -IncludeBonus -TargetAgents $config['TargetAgents']
Write-Step "Pre-cleanup score: $($preCleanupScore.TotalScore)/$($preCleanupScore.MaxScore) ($($preCleanupScore.Grade))" "INFO"

$cleanupStats = @{ Deduped = 0; Orphaned = 0; IndexRebuilt = $false; Reverted = $false }

# ── Step 1: Find duplicate docs (>70% content overlap) ──
Write-Step "Step 1: Scanning for duplicate docs..." "INFO"
$docDirs = @()
if (Test-Path (Join-Path $workDir "docs")) { $docDirs += Get-ChildItem (Join-Path $workDir "docs") -Directory -Recurse | Where-Object { $_.Name -notmatch '^\.' } }
if (Test-Path (Join-Path $workDir "copilot-docs")) { $docDirs += Get-ChildItem (Join-Path $workDir "copilot-docs") -Directory -Recurse | Where-Object { $_.Name -notmatch '^\.' } }

$allDocs = @()
foreach ($dir in $docDirs) {
    $allDocs += Get-ChildItem $dir.FullName -Filter "*.md" -File -ErrorAction SilentlyContinue
}
# Also get docs in root doc folders
foreach ($rootDocDir in @("docs", "copilot-docs")) {
    $rootPath = Join-Path $workDir $rootDocDir
    if (Test-Path $rootPath) {
        $allDocs += Get-ChildItem $rootPath -Filter "*.md" -File -ErrorAction SilentlyContinue
    }
}
$allDocs = @($allDocs | Sort-Object FullName -Unique)

# Build word-bag fingerprints for each doc
$docFingerprints = @{}
foreach ($doc in $allDocs) {
    try {
        $content = Get-Content $doc.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content -or $content.Length -lt 50) { continue }
        # Normalize: lowercase, strip markdown syntax, extract words
        $words = ($content.ToLower() -replace '[#*`\[\]()|\-_>]', ' ' -split '\s+' | Where-Object { $_.Length -gt 3 }) | Sort-Object -Unique
        $docFingerprints[$doc.FullName] = @{ Words = $words; File = $doc; Size = $content.Length }
    } catch { }
}

$duplicatePairs = @()
$docPaths = @($docFingerprints.Keys)
for ($i = 0; $i -lt $docPaths.Count; $i++) {
    for ($j = $i + 1; $j -lt $docPaths.Count; $j++) {
        $a = $docFingerprints[$docPaths[$i]]
        $b = $docFingerprints[$docPaths[$j]]
        if ($a.Words.Count -eq 0 -or $b.Words.Count -eq 0) { continue }

        # Jaccard similarity on word sets
        $intersection = @($a.Words | Where-Object { $b.Words -contains $_ }).Count
        $union = @($a.Words + $b.Words | Sort-Object -Unique).Count
        $similarity = if ($union -gt 0) { $intersection / $union } else { 0 }

        if ($similarity -gt 0.70) {
            $duplicatePairs += @{
                FileA      = $docPaths[$i]
                FileB      = $docPaths[$j]
                Similarity = [Math]::Round($similarity * 100, 1)
                SizeA      = $a.Size
                SizeB      = $b.Size
            }
        }
    }
}

if ($duplicatePairs.Count -gt 0) {
    Write-Step "Found $($duplicatePairs.Count) duplicate doc pair(s) (>70% overlap)" "WARN"
    foreach ($pair in $duplicatePairs) {
        # Keep the larger file (more content), remove the smaller
        $removeFile = if ($pair.SizeA -ge $pair.SizeB) { $pair.FileB } else { $pair.FileA }
        $keepFile = if ($pair.SizeA -ge $pair.SizeB) { $pair.FileA } else { $pair.FileB }
        $relRemove = $removeFile.Replace($workDir, "").TrimStart("\", "/")
        $relKeep = $keepFile.Replace($workDir, "").TrimStart("\", "/")
        Write-Step "  Removing '$relRemove' (dup of '$relKeep', $($pair.Similarity)% overlap)" "INFO"
        Remove-Item $removeFile -Force -ErrorAction SilentlyContinue
        $cleanupStats.Deduped++
    }
} else {
    Write-Step "No duplicate docs found" "OK"
}

# ── Step 2: Remove orphan docs (all code refs dead) ──
Write-Step "Step 2: Checking for orphan docs (all code refs dead)..." "INFO"
$codeExtensions = @('cs', 'py', 'ts', 'js', 'java', 'go')
$sourceFiles = @()
foreach ($ext in $codeExtensions) {
    $sourceFiles += Get-ChildItem $workDir -Filter "*.$ext" -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/](bin|obj|node_modules|\.monkey-output)[\\/]' }
}
$sourceNames = @($sourceFiles | ForEach-Object { $_.BaseName.ToLower() }) | Sort-Object -Unique

foreach ($doc in $allDocs) {
    if (-not (Test-Path $doc.FullName)) { continue }  # may have been deduped
    try {
        $content = Get-Content $doc.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }
        # Extract potential code references (PascalCase names that look like classes/methods)
        $codeRefs = [regex]::Matches($content, '`([A-Z][a-zA-Z0-9]{3,})`') | ForEach-Object { $_.Groups[1].Value.ToLower() }
        if ($codeRefs.Count -lt 3) { continue }  # skip docs with few code refs

        $aliveRefs = @($codeRefs | Where-Object { $sourceNames -contains $_ }).Count
        $deadPct = if ($codeRefs.Count -gt 0) { [Math]::Round((($codeRefs.Count - $aliveRefs) / $codeRefs.Count) * 100) } else { 0 }

        if ($deadPct -ge 90 -and $codeRefs.Count -ge 5) {
            $relPath = $doc.FullName.Replace($workDir, "").TrimStart("\", "/")
            Write-Step "  Orphan: '$relPath' ($deadPct% dead refs, $($codeRefs.Count) total)" "WARN"
            Remove-Item $doc.FullName -Force -ErrorAction SilentlyContinue
            $cleanupStats.Orphaned++
        }
    } catch { }
}
Write-Step "Removed $($cleanupStats.Orphaned) orphan doc(s)" $(if ($cleanupStats.Orphaned -gt 0) { "WARN" } else { "OK" })

# ── Step 3: Rebuild index files ──
Write-Step "Step 3: Rebuilding index files..." "INFO"
$docRootDirs = @()
foreach ($rootDocDir in @("docs\agentKT\workflows", "docs\agentKT\adr", "copilot-docs\workflows", "copilot-docs\adr")) {
    $dirPath = Join-Path $workDir $rootDocDir
    if (Test-Path $dirPath) { $docRootDirs += $dirPath }
}

foreach ($indexDir in $docRootDirs) {
    $readmePath = Join-Path $indexDir "README.md"
    $mdFiles = @(Get-ChildItem $indexDir -Filter "*.md" -File | Where-Object { $_.Name -ne "README.md" } | Sort-Object Name)
    if ($mdFiles.Count -eq 0) { continue }

    $dirName = Split-Path $indexDir -Leaf
    $indexLines = @("# $dirName Index", "", "| # | File | Title |", "|---|------|-------|")
    $num = 0
    foreach ($f in $mdFiles) {
        $num++
        $title = (Get-Content $f.FullName -TotalCount 5 | Where-Object { $_ -match '^#\s+' } | Select-Object -First 1) -replace '^#\s+', ''
        if (-not $title) { $title = $f.BaseName }
        $indexLines += "| $num | [$($f.Name)]($($f.Name)) | $title |"
    }
    $indexLines += "", "*Auto-generated by Monkey Army cleanup phase. $($mdFiles.Count) docs.*"
    Set-Content $readmePath -Value ($indexLines -join "`n") -Encoding UTF8
    Write-Step "  Rebuilt $dirName/README.md ($($mdFiles.Count) entries)" "OK"
}
$cleanupStats.IndexRebuilt = $true

# ── Step 4: Score guard — ensure cleanup didn't reduce health score ──
Write-Step "Step 4: Score guard check..." "INFO"
$postCleanupScore = Get-DocHealthScore -RepoPath $workDir -IncludeBonus -TargetAgents $config['TargetAgents']
$scoreDelta = $postCleanupScore.TotalScore - $preCleanupScore.TotalScore

if ($scoreDelta -lt 0) {
    Write-Step "⚠️ Score DROPPED by $([Math]::Abs($scoreDelta)) points ($($preCleanupScore.TotalScore) → $($postCleanupScore.TotalScore)) — reverting cleanup" "ERROR"
    Push-Location $workDir
    & git checkout -- . 2>&1 | Out-Null
    Pop-Location
    $cleanupStats.Reverted = $true
    Write-Step "Cleanup reverted — no changes applied" "WARN"
} else {
    Write-Step "Score guard passed: $($preCleanupScore.TotalScore) → $($postCleanupScore.TotalScore) (delta: +$scoreDelta)" "OK"

    # Commit cleanup changes
    Push-Location $workDir
    $cleanupChanges = @(& git --no-pager status --porcelain 2>&1 | Where-Object { $_ }).Count
    if ($cleanupChanges -gt 0) {
        & git add -A 2>&1 | Out-Null
        $outputDirRel = ".monkey-output"
        & git reset -- $outputDirRel 2>&1 | Out-Null
        $stagedCount = @(& git --no-pager diff --cached --name-only 2>&1).Count
        if ($stagedCount -gt 0) {
            $cleanMsg = "docs: 🧹 post-run cleanup — $($cleanupStats.Deduped) deduped, $($cleanupStats.Orphaned) orphans removed, indexes rebuilt`n`nScore: $($preCleanupScore.TotalScore) → $($postCleanupScore.TotalScore) (delta: +$scoreDelta)`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>"
            & git commit -m $cleanMsg 2>&1 | Out-Null
            Write-Step "Committed cleanup: $stagedCount files changed" "OK"
        }
    }
    Pop-Location
}

Write-Step "Cleanup complete: $($cleanupStats.Deduped) deduped, $($cleanupStats.Orphaned) orphans, indexes=$(if ($cleanupStats.IndexRebuilt) {'rebuilt'} else {'skipped'}), reverted=$($cleanupStats.Reverted)" "INFO"

# ══════════════════════════════════════════════════════════════════
#  PHASE 6: UNIFIED REPORT
# ══════════════════════════════════════════════════════════════════

$armyElapsed = (Get-Date) - $armyStart

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║          🐒 MONKEY ARMY — MISSION REPORT            ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""

# Per-monkey results table
Write-Host "  Monkey Results:" -ForegroundColor White
Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
$fmt = "  {0,-3} {1,-18} {2,-10} {3,-8} {4,-8} {5,-10}"
Write-Host ($fmt -f "Ph", "Monkey", "Status", "Asked", "Ans", "Duration") -ForegroundColor DarkGray

foreach ($m in $config.OrderedMonkeys) {
    $r = $results[$m.Id]
    if (-not $r) { continue }
    $color = switch ($r.ExitStatus) { 'SUCCESS' { 'Green' } 'PARTIAL' { 'Yellow' } 'SKIPPED' { 'DarkGray' } default { 'Red' } }
    $healed = if ($m.Id -in $healedMonkeys) { " 🩹" } else { "" }
    Write-Host ($fmt -f $m.Phase, "$($m.Emoji) $($m.Name)$healed", $r.ExitStatus, $r.QuestionsAsked, $r.QuestionsAnswered, $r.Duration) -ForegroundColor $color
}

Write-Host "  ─────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host ""

# Summary stats
$summaryStats = @{
    "Pack"              = $config.Pack
    "Monkeys Run"       = $config.OrderedMonkeys.Count
    "Succeeded"         = $successCount
    "Partial"           = $partialCount
    "Failed"            = $failedCount
    "Skipped"           = $skippedCount
    "Healed"            = $healedMonkeys.Count
    "Total Asked"       = $totalAsked
    "Total Answered"    = $totalAnswered
    "Answer Rate"       = "$answerRate%"
    "Total Retries"     = $totalRetries
    "Files Changed"     = $totalFiles
    "Quality Gate"      = $gateVerdict
    "Duration"          = $armyElapsed.ToString('hh\:mm\:ss')
    "Model"             = if ($selectedModel) { $selectedModel } else { "(default)" }
    "Branch"            = $branchName
    "PR"                = if ($prResult -and $prResult.Created) { $prResult.Url } else { "N/A" }
}

Write-MonkeySummary -Stats $summaryStats -Emoji "🐒"

# ── After score ───────────────────────────────────────────────────
Write-Phase "SCORE" "Measuring repo health (after)"
$afterScore = Get-DocHealthScore -RepoPath $workDir -IncludeBonus -TargetAgents $config['TargetAgents']

# ── Before vs After ──────────────────────────────────────────────
Show-ScoreDelta -Before $beforeScore -After $afterScore

# Save unified report
$unifiedReport = @{
    Timestamp     = (Get-Date).ToString('o')
    Config        = @{
        Pack      = $config.Pack
        Monkeys   = $config.SelectedMonkeys
        Model     = $selectedModel
        Branch    = $branchName
        CommitMode = $config.CommitMode
    }
    Results       = $results
    QualityGate   = @{
        Pass    = $gatePass
        Reasons = $gateReasons
        Verdict = $gateVerdict
    }
    HealedMonkeys = $healedMonkeys
    Summary       = $summaryStats
    Cleanup       = $cleanupStats
    HealthScore   = @{
        Before = $beforeScore
        After  = $afterScore
        Delta  = $afterScore.TotalScore - $beforeScore.TotalScore
        GradeChange = "$($beforeScore.Grade) → $($afterScore.Grade)"
    }
    Duration      = $armyElapsed.ToString('hh\:mm\:ss')
}
$unifiedReport | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $outputRoot "army-report.json") -Encoding UTF8

Write-Host ""
Write-Host "  📁 Full report: $(Join-Path $outputRoot 'army-report.json')" -ForegroundColor Cyan

# ── Clean up checkpoint on successful completion ──
if ($gatePass) {
    Remove-RunCheckpoint -OutputRoot $outputRoot
    Write-Host "  🔖 Checkpoint cleared (run complete)" -ForegroundColor DarkGray
} else {
    Write-Host "  🔖 Checkpoint preserved (quality gate failed — use -Resume to retry)" -ForegroundColor Yellow
}

Write-Host "  🐒 Monkey Army mission complete!" -ForegroundColor Green
Write-Host ""
