# ─────────────────────────────────────────────
# MonkeyCommon.psm1 — Shared infrastructure for Monkey Army 🐒
# Provides: UI helpers, copilot invocation, git/setup, model selection,
#           pre-validation, doc-reference parsing, commit/stage, preflight
# ─────────────────────────────────────────────

Set-StrictMode -Version Latest

# ─────────────────────────────────────────────
# Region: Constants
# ─────────────────────────────────────────────

# Retry-related error patterns
$script:RETRYABLE_PATTERNS = @(
    'capacity'
    'rate.?limit'
    '429'
    '503'
    'overloaded'
    'try again'
    'too many requests'
    'server error'
    'timeout'
    'ETIMEDOUT'
    'ECONNRESET'
)

# Model probe order (best coding models first)
$script:MODEL_PRIORITY = @(
    "claude-sonnet-4"
    "gpt-4.1"
)

# Doc-reference detection patterns (generic — works on any repo)
$script:DocRefPatterns = @(
    @{ Name = 'docs_path';    Pattern = 'docs[/\\]' }
    @{ Name = 'md_file';      Pattern = '[\w\-]+\.md' }
    @{ Name = 'workflow';     Pattern = 'workflow[s]?\s*(doc|file|ref)' }
    @{ Name = 'readme';       Pattern = 'README\.md|readme\.md' }
    @{ Name = 'wiki_ref';     Pattern = 'wiki[/\\]|\.wiki\b' }
    @{ Name = 'doc_dir';      Pattern = 'doc[/\\]|documentation[/\\]' }
    @{ Name = 'api_doc';      Pattern = 'swagger|openapi|api[_-]?doc' }
    @{ Name = 'changelog';    Pattern = 'CHANGELOG|CHANGES|HISTORY' }
    @{ Name = 'guide_ref';    Pattern = 'guide[/\\]|tutorial|howto|getting.started' }
    @{ Name = 'arch_ref';     Pattern = 'architect|design[_-]?doc|ADR|decision' }
)

# ─────────────────────────────────────────────
# Region: UI Helpers
# ─────────────────────────────────────────────

function Write-MonkeyBanner {
    param(
        [string]$Name,
        [string]$Emoji,
        [string]$Version,
        [string]$Tagline
    )
    $banner = @"

  ╔══════════════════════════════════════════╗
  ║     $Emoji $Name v$Version $Emoji        ║
  ║   $Tagline   ║
  ╚══════════════════════════════════════════╝

"@
    Write-Host $banner -ForegroundColor Cyan
}

function Write-Phase {
    param([string]$Phase, [string]$Message)
    Write-Host "`n[$Phase] " -ForegroundColor Yellow -NoNewline
    Write-Host $Message -ForegroundColor White
    Write-Host ("─" * 60) -ForegroundColor DarkGray
}

function Write-Step {
    param([string]$Message, [string]$Status = "INFO")
    $color = switch ($Status) {
        "OK"    { "Green" }
        "WARN"  { "Yellow" }
        "ERROR" { "Red" }
        "SKIP"  { "DarkGray" }
        default { "Cyan" }
    }
    Write-Host "  [$Status] " -ForegroundColor $color -NoNewline
    Write-Host $Message
}

function Write-MonkeySummary {
    param(
        [hashtable]$Stats,
        [string]$Emoji = "🐵"
    )
    Write-Host "`n" -NoNewline
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║          $Emoji RUN SUMMARY                  ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Cyan
    foreach ($key in $Stats.Keys | Sort-Object) {
        $val = $Stats[$key]
        $color = "White"
        if ($key -match 'Failed|Error' -and $val -gt 0) { $color = "Red" }
        elseif ($key -match 'Answered|OK|Grounded' -and $val -gt 0) { $color = "Green" }
        elseif ($key -match 'Retry|Warn' -and $val -gt 0) { $color = "Yellow" }
        $paddedKey = $key.PadRight(25)
        Write-Host "  $paddedKey : $val" -ForegroundColor $color
    }
    Write-Host ""
}

# ─────────────────────────────────────────────
# Region: Copilot Invocation with Retry
# ─────────────────────────────────────────────

function Invoke-CopilotWithRetry {
    <#
    .SYNOPSIS
        Invokes copilot -p with retry logic, timeout handling, and error classification.
        Uses PowerShell jobs for timeout support (avoids Process wrapper issues with .ps1 shims).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Prompt,

        [string]$ModelName,

        [string]$SharePath,

        [string]$WorkingDirectory,

        [int]$Retries = 3,

        [int]$BaseDelay = 30,

        [int]$Timeout = 300,

        [switch]$ShowVerbose
    )

    $attempt = 0
    $lastError = $null

    while ($attempt -le $Retries) {
        if ($attempt -gt 0) {
            $delay = $BaseDelay * [math]::Pow(2, $attempt - 1)
            Write-Step "Retry $attempt/$Retries in ${delay}s..." "WARN"
            Start-Sleep -Seconds $delay
        }

        try {
            $copilotArgs = @("-p", $Prompt, "--yolo", "--no-ask-user", "-s")
            if ($ModelName) { $copilotArgs += @("--model", $ModelName) }
            if ($SharePath) { $copilotArgs += @("--share=$SharePath") }

            $job = Start-Job -ScriptBlock {
                param($wd, $args_)
                Set-Location $wd
                $output = & copilot @args_ 2>&1
                @{
                    ExitCode = $LASTEXITCODE
                    Output   = ($output | Out-String).Trim()
                }
            } -ArgumentList $WorkingDirectory, $copilotArgs

            $completed = $job | Wait-Job -Timeout $Timeout

            if (-not $completed) {
                $job | Stop-Job -ErrorAction SilentlyContinue
                $job | Remove-Job -Force -ErrorAction SilentlyContinue
                $lastError = "TIMEOUT after ${Timeout}s"
                Write-Step "Call timed out after ${Timeout}s" "WARN"
                $attempt++
                continue
            }

            $jobResult = $job | Receive-Job
            $job | Remove-Job -Force -ErrorAction SilentlyContinue

            $exitCode = $jobResult.ExitCode
            $stdout = $jobResult.Output

            if ($ShowVerbose -and $stdout) {
                Write-Host $stdout -ForegroundColor DarkGray
            }

            if ($exitCode -eq 0 -or $null -eq $exitCode) {
                return @{
                    Success = $true
                    Output  = $stdout
                    Stderr  = ""
                    Retries = $attempt
                }
            }

            # Check if error is retryable
            $isRetryable = $false
            foreach ($pattern in $script:RETRYABLE_PATTERNS) {
                if ($stdout -match $pattern) {
                    $isRetryable = $true
                    break
                }
            }

            if ($isRetryable) {
                $lastError = $stdout
                Write-Step "Retryable error: $($stdout.Substring(0, [Math]::Min(100, $stdout.Length)))" "WARN"
                $attempt++
                continue
            }

            return @{
                Success = $false
                Output  = $stdout
                Stderr  = ""
                Error   = "Exit code $exitCode`: $stdout"
                Retries = $attempt
            }
        }
        catch {
            $lastError = $_.Exception.Message
            Write-Step "Exception: $lastError" "ERROR"
            $attempt++
            continue
        }
    }

    return @{
        Success = $false
        Output  = ""
        Stderr  = ""
        Error   = "All $Retries retries exhausted. Last error: $lastError"
        Retries = $attempt
    }
}

# ─────────────────────────────────────────────
# Region: Doc-Reference Parsing
# ─────────────────────────────────────────────

function Get-DocReferences {
    <#
    .SYNOPSIS
        Parses a copilot response for documentation references.
        Returns a hashtable with reference counts and matched doc paths.
    #>
    param([string]$ResponseText)

    $refs = @{
        TotalRefs     = 0
        DocPaths      = @()
        PatternHits   = @{}
        IsDocGrounded = $false
    }

    if (-not $ResponseText) { return $refs }

    foreach ($p in $script:DocRefPatterns) {
        $matches_ = [regex]::Matches($ResponseText, $p.Pattern, 'IgnoreCase')
        if ($matches_.Count -gt 0) {
            $refs.PatternHits[$p.Name] = $matches_.Count
            $refs.TotalRefs += $matches_.Count
        }
    }

    $mdPaths = [regex]::Matches($ResponseText, '[\w\-/\\]+\.md', 'IgnoreCase')
    $refs.DocPaths = @($mdPaths | ForEach-Object { $_.Value } | Sort-Object -Unique)
    $refs.IsDocGrounded = ($refs.TotalRefs -gt 0)
    return $refs
}

# ─────────────────────────────────────────────
# Region: Setup (Clone / Branch)
# ─────────────────────────────────────────────

function Invoke-MonkeySetup {
    <#
    .SYNOPSIS
        Shared setup: resolve branch, clone/locate repo, create working branch, output dir.
    #>
    param(
        [string]$RepoUrl,
        [string]$ClonePath,
        [string]$RepoPath,
        [string]$BaseBranch,
        [switch]$UseBaseBranch,
        [string]$BranchName,
        [string]$BranchPrefix = "monkey",
        [string]$OutputDirName = ".monkey-output",
        [switch]$NonInteractive
    )

    Write-Phase "PHASE 1" "Setup — Clone / Branch"

    $workDir = $null

    # ── Resolve base branch ──
    if (-not $BaseBranch) {
        if (-not $NonInteractive -and $RepoPath -and (Test-Path $RepoPath)) {
            Push-Location $RepoPath
            Write-Host ""
            Write-Host "  Available remote branches:" -ForegroundColor Cyan
            $branches = & git --no-pager branch -r 2>&1 | ForEach-Object { $_.Trim() -replace '^origin/', '' } | Where-Object { $_ -and $_ -notmatch 'HEAD' } | Select-Object -First 20
            Pop-Location
            for ($i = 0; $i -lt $branches.Count; $i++) {
                Write-Host "    [$i] $($branches[$i])" -ForegroundColor DarkGray
            }
            Write-Host ""
            $userInput = Read-Host "  Enter base branch name or number (default: develop)"
            if ([string]::IsNullOrWhiteSpace($userInput)) {
                $BaseBranch = "develop"
            }
            elseif ($branches -and $userInput -match '^\d+$' -and [int]$userInput -lt $branches.Count) {
                $BaseBranch = $branches[[int]$userInput]
            }
            else {
                $BaseBranch = $userInput
            }
        }
        else {
            $BaseBranch = "develop"
        }
        Write-Step "Base branch: $BaseBranch" "OK"
    }

    # ── Clone or locate repo ──
    if ($RepoPath) {
        if (-not (Test-Path $RepoPath)) {
            throw "RepoPath '$RepoPath' does not exist."
        }
        $workDir = Resolve-Path $RepoPath
        Write-Step "Using existing repo: $workDir" "OK"
    }
    elseif ($RepoUrl) {
        if ($ClonePath -eq ".\monkey-workspace" -and -not $NonInteractive) {
            Write-Host ""
            $userClonePath = Read-Host "  Where should we clone the repo? (default: $ClonePath)"
            if (-not [string]::IsNullOrWhiteSpace($userClonePath)) {
                $ClonePath = $userClonePath
            }
        }
        if (Test-Path $ClonePath) {
            Write-Step "Clone path exists, reusing..." "INFO"
            $workDir = Resolve-Path $ClonePath
        }
        else {
            New-Item -ItemType Directory -Path $ClonePath -Force | Out-Null
            Write-Step "Shallow cloning $RepoUrl → $ClonePath (depth=1, branch=$BaseBranch)" "INFO"
            & git clone --depth 1 --branch $BaseBranch $RepoUrl $ClonePath 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
            $workDir = Resolve-Path $ClonePath
            Write-Step "Shallow clone complete (no history)" "OK"
        }
    }
    else {
        throw "Either -RepoUrl or -RepoPath must be provided."
    }

    Push-Location $workDir

    # ── Checkout base branch ──
    Write-Step "Checking out '$BaseBranch' and pulling latest..." "INFO"
    & git checkout $BaseBranch 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        & git checkout -b $BaseBranch "origin/$BaseBranch" 2>&1 | Out-Null
    }
    $isShallow = Test-Path (Join-Path $workDir ".git/shallow")
    if (-not $isShallow) {
        & git pull origin $BaseBranch 2>&1 | Out-Null
    }
    Write-Step "On latest '$BaseBranch'" "OK"

    # ── Branch strategy ──
    $actualBranch = $null
    if (-not $UseBaseBranch -and -not $BranchName) {
        if ($NonInteractive) {
            # Non-interactive default: create new branch
            Write-Step "Non-interactive: creating new branch" "INFO"
        }
        else {
            Write-Host ""
            $branchChoice = Read-Host "  Branch strategy: [1] Create new branch ($BranchPrefix/<timestamp>) or [2] Work on '$BaseBranch' directly? (default: 1)"
            if ($branchChoice -eq '2') {
                $UseBaseBranch = $true
            }
        }
    }

    if ($UseBaseBranch) {
        $actualBranch = $BaseBranch
        Write-Step "Working directly on '$BaseBranch'" "OK"
    }
    else {
        if (-not $BranchName) {
            $timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $BranchName = "$BranchPrefix/$timestamp"
        }
        & git checkout -b $BranchName 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Failed to create branch '$BranchName'" }
        $actualBranch = $BranchName
        Write-Step "Created branch: $BranchName" "OK"
    }

    # ── Output directory ──
    $outputPath = Join-Path $workDir $OutputDirName
    New-Item -ItemType Directory -Path $outputPath -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $outputPath "session-logs") -Force | Out-Null
    Write-Step "Output dir: $outputPath" "OK"

    Pop-Location

    return @{
        WorkDir    = [string]$workDir
        Branch     = $actualBranch
        BaseBranch = $BaseBranch
        OutputPath = [string]$outputPath
    }
}

# ─────────────────────────────────────────────
# Region: Preflight
# ─────────────────────────────────────────────

function Test-Preflight {
    Write-Phase "PREFLIGHT" "Checking prerequisites"

    # Copilot CLI
    $copilotPath = Get-Command copilot -ErrorAction SilentlyContinue
    if (-not $copilotPath) {
        throw "copilot CLI not found. Install: npm install -g @anthropic/copilot-cli (or GitHub Copilot CLI)"
    }
    $copilotVersion = (& copilot --version 2>&1 | Select-Object -First 1)
    Write-Step "Copilot CLI: $copilotVersion ($($copilotPath.Source))" "OK"

    # Git
    $gitPath = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitPath) { throw "git not found" }
    $gitVersion = (& git --version 2>&1 | Select-Object -First 1)
    Write-Step "Git: $gitVersion" "OK"

    # PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        Write-Step "PowerShell 7+ recommended (current: $($PSVersionTable.PSVersion))" "WARN"
    }
    else {
        Write-Step "PowerShell: $($PSVersionTable.PSVersion)" "OK"
    }
}

# ─────────────────────────────────────────────
# Region: Pre-Validation
# ─────────────────────────────────────────────

function Test-CopilotInRepo {
    param(
        [string]$WorkingDirectory,
        [switch]$NonInteractive
    )

    Write-Phase "PRE-VALIDATION" "Verifying Copilot & Self-Healing in repo context"

    # Check 1: Basic invocation
    Write-Step "Check 1/3: Testing basic copilot -p invocation..." "INFO"
    $basic = Invoke-CopilotWithRetry -Prompt "Respond with only the word: VALIDATED" -WorkingDirectory $WorkingDirectory -Retries 1 -BaseDelay 5 -Timeout 120
    if (-not $basic.Success) {
        Write-Step "copilot -p FAILED. Error: $($basic.Error)" "ERROR"
        throw "Pre-validation failed: copilot -p does not work in $WorkingDirectory"
    }
    if ($basic.Output -notmatch 'VALIDATED') {
        Write-Step "copilot -p responded but output unexpected: $($basic.Output.Substring(0, [Math]::Min(80, $basic.Output.Length)))" "WARN"
    }
    else {
        Write-Step "copilot -p works ✓" "OK"
    }

    # Check 2: Custom instructions
    Write-Step "Check 2/3: Verifying custom instructions are loaded..." "INFO"
    $instructionCheck = Invoke-CopilotWithRetry -Prompt "List the custom instruction files you loaded for this repo. Output ONLY the filenames, one per line. If none, say NONE." -WorkingDirectory $WorkingDirectory -Retries 1 -BaseDelay 5 -Timeout 120
    if ($instructionCheck.Success) {
        $instrOutput = $instructionCheck.Output
        if ($instrOutput -match 'NONE' -or [string]::IsNullOrWhiteSpace($instrOutput)) {
            Write-Step "No custom instructions detected. Self-healing may not trigger!" "WARN"
            if (-not $NonInteractive) {
                $continue = Read-Host "    Continue anyway? [Y/n]"
                if ($continue -match '^[Nn]') {
                    throw "Aborted: No custom instructions found."
                }
            }
            else {
                Write-Step "Non-interactive: continuing without custom instructions" "INFO"
            }
        }
        else {
            $fileCount = @($instrOutput -split "`n" | Where-Object { $_.Trim() }).Count
            Write-Step "Custom instructions loaded ($fileCount files) ✓" "OK"
            foreach ($line in @($instrOutput -split "`n" | Where-Object { $_.Trim() } | Select-Object -First 10)) {
                Write-Host "    → $($line.Trim())" -ForegroundColor DarkGray
            }
        }
    }
    else {
        Write-Step "Could not verify instructions (non-fatal): $($instructionCheck.Error)" "WARN"
    }

    # Check 3: Deferred to execution
    Write-Step "Check 3/3: Self-healing will be verified during execution (tracking per question)" "OK"
    Write-Step "Pre-validation complete" "OK"
}

# ─────────────────────────────────────────────
# Region: Model Auto-Selection
# ─────────────────────────────────────────────

function Select-MonkeyModel {
    param(
        [string]$UserModel,
        [string]$WorkingDirectory,
        [switch]$NonInteractive
    )

    if ($UserModel) {
        Write-Step "Using user-specified model: $UserModel" "OK"
        return $UserModel
    }

    Write-Step "Auto-detecting best available model..." "INFO"
    foreach ($model in $script:MODEL_PRIORITY) {
        Write-Step "Probing $model..." "INFO"
        $probe = Invoke-CopilotWithRetry -Prompt "Respond with only: OK" -ModelName $model -WorkingDirectory $WorkingDirectory -Retries 0 -BaseDelay 5 -Timeout 120
        if ($probe.Success -and $probe.Output -match 'OK') {
            Write-Step "Model available: $model ✓" "OK"
            if (-not $NonInteractive) {
                Write-Host ""
                $override = Read-Host "  Use ${model}? (Enter to accept, or type model name to override)"
                if (-not [string]::IsNullOrWhiteSpace($override)) {
                    Write-Step "User override: $override" "OK"
                    return $override
                }
            }
            return $model
        }
        Write-Step "$model not available, trying next..." "WARN"
    }

    Write-Step "No preferred models available. Using copilot default." "WARN"
    return $null
}

# ─────────────────────────────────────────────
# Region: Commit / Stage
# ─────────────────────────────────────────────

function Invoke-MonkeyCommit {
    param(
        [string]$WorkingDirectory,
        [string]$OutputDirName,
        [string]$MonkeyName,
        [string]$MonkeyEmoji,
        [string]$BranchName,
        [string]$ModelName,
        [int]$QuestionsAnswered,
        [switch]$DryRun,
        [switch]$Commit
    )

    Write-Phase "PHASE 5" "Commit / Stage"

    Push-Location $WorkingDirectory

    try {
        $changes = & git --no-pager status --porcelain 2>&1
        $changedFiles = @($changes | Where-Object { $_ -and $_ -notmatch '^\?\?' -and $_ -notmatch $OutputDirName }).Count
        $newFiles = @($changes | Where-Object { $_ -match '^\?\?' -and $_ -notmatch $OutputDirName }).Count

        Write-Step "Changed files: $changedFiles | New files: $newFiles" "INFO"

        if (($changedFiles + $newFiles) -eq 0) {
            Write-Step "No documentation changes detected." "WARN"
            return 0
        }

        & git add -A 2>&1 | Out-Null
        $outputPath = Join-Path $WorkingDirectory $OutputDirName
        & git reset -- $outputPath 2>&1 | Out-Null

        $stagedCount = (& git --no-pager diff --cached --name-only 2>&1 | Measure-Object).Count

        if ($stagedCount -eq 0) {
            Write-Step "No files to commit after filtering." "WARN"
            return 0
        }

        Write-Step "Staged $stagedCount files" "OK"
        $stagedFiles = & git --no-pager diff --cached --name-only 2>&1
        foreach ($f in $stagedFiles) {
            Write-Host "    + $f" -ForegroundColor Green
        }

        if ($DryRun) {
            Write-Step "DRY RUN — changes staged but NOT committed." "WARN"
            return $stagedCount
        }

        if ($Commit) {
            $commitMsg = @"
docs: $MonkeyName $MonkeyEmoji auto-generated documentation

Auto-generated by $MonkeyName autonomous doc-generation tool.
Branch: $BranchName
Model: $ModelName
Questions answered: $QuestionsAnswered

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
"@
            & git commit -m $commitMsg 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) {
                Write-Step "Commit failed!" "ERROR"
                return $stagedCount
            }
            Write-Step "Committed to '$BranchName'" "OK"
        }
        else {
            Write-Step "Changes staged. Use -Commit or -DryRun to control behavior." "WARN"
        }

        return $stagedCount
    }
    finally {
        Pop-Location
    }
}

# ─────────────────────────────────────────────
# Region: Question Execution (Phase 4 shared loop)
# ─────────────────────────────────────────────

function Invoke-MonkeyQuestions {
    <#
    .SYNOPSIS
        Shared Phase 4: feeds questions to copilot, tracks doc refs + file changes per answer.
    #>
    param(
        [array]$Questions,
        [string]$WorkingDirectory,
        [string]$OutputPath,
        [string]$ModelName,
        [string]$MonkeyEmoji = "🐵",
        [int]$MaxRetries = 3,
        [int]$RetryBaseDelay = 30,
        [int]$CallTimeout = 300,
        [switch]$ShowVerbose
    )

    Write-Phase "PHASE 4" "Execution — Asking Copilot ($($Questions.Count) questions)"

    $stats = @{
        Answered         = 0
        Failed           = 0
        Retries          = 0
        FileChanges      = 0
        DocGroundedCount = 0
        HealingQuestions = @()
        QuestionDetails  = @()
    }
    $failedQuestions = @()
    $totalQ = $Questions.Count
    $currentQ = 0

    Push-Location $WorkingDirectory

    foreach ($q in $Questions) {
        $currentQ++
        $pct = [Math]::Round(($currentQ / $totalQ) * 100)
        $entryLabel = if ($q.EntryPoint) { $q.EntryPoint } else { "general" }
        Write-Progress -Activity "$MonkeyEmoji answering questions" -Status "$currentQ/$totalQ — $entryLabel" -PercentComplete $pct

        $beforeStatus = & git --no-pager status --porcelain 2>&1

        # Build prompt — Abu may not always have an EntryPoint
        $docHealSuffix = " If relevant documentation for this topic is missing or incomplete in the repo, create or update it following existing doc patterns."
        $prompt = if ($q.EntryPoint) {
            "Regarding the file '$($q.EntryPoint)': $($q.Question)$docHealSuffix"
        } else {
            "$($q.Question)$docHealSuffix"
        }

        $safeName = if ($q.EntryPoint) {
            ($q.EntryPoint -replace '[\\/:*?"<>|]', '_') -replace '\.cs$|\.py$|\.java$|\.go$|\.ts$|\.js$', ''
        } else {
            "general_$currentQ"
        }
        $sharePath = Join-Path $OutputPath "session-logs" ("{0:D3}-{1}.md" -f $currentQ, $safeName)

        Write-Step "[$currentQ/$totalQ] $($q.Question.Substring(0, [Math]::Min(80, $q.Question.Length)))..." "INFO"

        $result = Invoke-CopilotWithRetry -Prompt $prompt -ModelName $ModelName -SharePath $sharePath -WorkingDirectory $WorkingDirectory -Retries $MaxRetries -BaseDelay $RetryBaseDelay -Timeout $CallTimeout -ShowVerbose:$ShowVerbose

        $stats.Retries += $result.Retries

        if ($result.Success) {
            $stats.Answered++

            # Signal 1: Doc-reference parsing
            $docRefs = Get-DocReferences -ResponseText $result.Output
            if ($docRefs.IsDocGrounded) { $stats.DocGroundedCount++ }

            # Also parse transcript
            if (Test-Path $sharePath) {
                $transcript = Get-Content $sharePath -Raw -ErrorAction SilentlyContinue
                if ($transcript) {
                    $transcriptRefs = Get-DocReferences -ResponseText $transcript
                    if ($transcriptRefs.IsDocGrounded -and -not $docRefs.IsDocGrounded) {
                        $docRefs = $transcriptRefs
                        $stats.DocGroundedCount++
                    }
                    elseif ($transcriptRefs.IsDocGrounded) {
                        $docRefs = $transcriptRefs
                    }
                }
            }

            # Signal 2: File changes
            $afterStatus = & git --no-pager status --porcelain 2>&1
            $newChanges = @($afterStatus | Where-Object { $_ -notin $beforeStatus })
            $hasFileChanges = $newChanges.Count -gt 0

            if ($hasFileChanges) {
                $stats.FileChanges += $newChanges.Count
                $stats.HealingQuestions += @{
                    Question     = $q.Question
                    EntryPoint   = $q.EntryPoint
                    FilesChanged = $newChanges.Count
                    Files        = @($newChanges | ForEach-Object { $_.Trim() })
                }
            }

            $verdict = switch ($true) {
                ($docRefs.IsDocGrounded -and $hasFileChanges) { "DOCS_REFERENCED+FILES_CHANGED" }
                ($docRefs.IsDocGrounded -and -not $hasFileChanges) { "DOCS_REFERENCED" }
                (-not $docRefs.IsDocGrounded -and $hasFileChanges) { "FILES_CHANGED" }
                default { "NO_DOC_SIGNAL" }
            }

            $stats.QuestionDetails += @{
                Index        = $currentQ
                EntryPoint   = $q.EntryPoint
                Question     = $q.Question
                Category     = if ($q.ContainsKey('Category')) { $q.Category } else { 'general' }
                Verdict      = $verdict
                DocGrounded  = $docRefs.IsDocGrounded
                DocPaths     = $docRefs.DocPaths
                DocRefCount  = $docRefs.TotalRefs
                FileChanges  = $newChanges.Count
            }

            if ($hasFileChanges) {
                Write-Step "Answered ✓ + $($newChanges.Count) file(s) changed (self-healing triggered!)" "OK"
                foreach ($change in $newChanges | Select-Object -First 5) {
                    Write-Host "      $change" -ForegroundColor Green
                }
            }
            elseif ($docRefs.IsDocGrounded) {
                Write-Step "Answered ✓ (refs $($docRefs.DocPaths.Count) docs — docs already complete)" "OK"
            }
            else {
                Write-Step "Answered ✓ (no doc signal)" "WARN"
            }
        }
        else {
            $stats.Failed++
            $failedQuestions += @{
                EntryPoint = $q.EntryPoint
                Question   = $q.Question
                Error      = $result.Error
            }
            Write-Step "FAILED: $($result.Error)" "ERROR"
        }
    }

    Pop-Location
    Write-Progress -Activity "$MonkeyEmoji answering questions" -Completed

    if ($failedQuestions.Count -gt 0) {
        $failedPath = Join-Path $OutputPath "failed-questions.json"
        $failedQuestions | ConvertTo-Json -Depth 5 | Set-Content $failedPath -Encoding UTF8
        Write-Step "$($failedQuestions.Count) failed questions saved to failed-questions.json" "WARN"
    }

    return $stats
}

# ─────────────────────────────────────────────
# Region: Report Generation
# ─────────────────────────────────────────────

function Save-MonkeyReport {
    param(
        [hashtable]$ExecStats,
        [string]$OutputPath,
        [string]$MonkeyName
    )

    $docGroundedPct = if ($ExecStats.Answered -gt 0) {
        [Math]::Round(($ExecStats.DocGroundedCount / $ExecStats.Answered) * 100, 1)
    } else { 0 }
    $noSignalCount = @($ExecStats.QuestionDetails | Where-Object { $_.Verdict -eq "NO_DOC_SIGNAL" }).Count

    # Healing report
    $healingReport = @{
        MonkeyName = $MonkeyName
        Summary = @{
            TotalAnswered       = $ExecStats.Answered
            DocGroundedCount    = $ExecStats.DocGroundedCount
            DocGroundedPct      = $docGroundedPct
            FileChangesTotal    = $ExecStats.FileChanges
            HealingTriggered    = $ExecStats.HealingQuestions.Count
            NoDocSignalCount    = $noSignalCount
        }
        Verdicts = @{
            DOCS_REFERENCED_FILES_CHANGED = @($ExecStats.QuestionDetails | Where-Object { $_.Verdict -eq "DOCS_REFERENCED+FILES_CHANGED" }).Count
            DOCS_REFERENCED               = @($ExecStats.QuestionDetails | Where-Object { $_.Verdict -eq "DOCS_REFERENCED" }).Count
            FILES_CHANGED                 = @($ExecStats.QuestionDetails | Where-Object { $_.Verdict -eq "FILES_CHANGED" }).Count
            NO_DOC_SIGNAL                 = $noSignalCount
        }
        QuestionDetails     = $ExecStats.QuestionDetails
        HealingQuestions    = $ExecStats.HealingQuestions
    }
    $healingReport | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputPath "healing-report.json") -Encoding UTF8

    # Coverage by entry point
    $epCoverage = $ExecStats.QuestionDetails | Group-Object EntryPoint | ForEach-Object {
        $grounded = @($_.Group | Where-Object { $_.DocGrounded }).Count
        @{
            EntryPoint             = $_.Name
            TotalQuestions         = $_.Count
            DocGrounded            = $grounded
            CoveragePct            = if ($_.Count -gt 0) { [Math]::Round(($grounded / $_.Count) * 100, 1) } else { 0 }
            UniqueDocsReferenced   = @($_.Group | ForEach-Object { $_.DocPaths } | Sort-Object -Unique)
        }
    }
    $epCoverage | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $OutputPath "doc-coverage-by-entrypoint.json") -Encoding UTF8

    # Display
    Write-Host "  Doc-Grounded Answers: $($ExecStats.DocGroundedCount)/$($ExecStats.Answered) ($docGroundedPct%)" -ForegroundColor $(if ($docGroundedPct -ge 70) { 'Green' } elseif ($docGroundedPct -ge 40) { 'Yellow' } else { 'Red' })
    Write-Host "  Reports: healing-report.json, doc-coverage-by-entrypoint.json" -ForegroundColor Cyan

    return @{
        DocGroundedPct   = $docGroundedPct
        NoDocSignalCount = $noSignalCount
    }
}

# ─────────────────────────────────────────────
# Region: Standardized Monkey Result
# ─────────────────────────────────────────────

function New-MonkeyResult {
    <#
    .SYNOPSIS
        Creates a standardized result object that every monkey returns.
        Ensures uniform shape for orchestrator consumption.
    #>
    param(
        [Parameter(Mandatory)][string]$MonkeyName,
        [TimeSpan]$Duration,
        [string]$Model,
        [ValidateSet('SUCCESS','PARTIAL','FAILED','SKIPPED')]
        [string]$ExitStatus = 'SUCCESS',
        [int]$QuestionsAsked      = 0,
        [int]$QuestionsAnswered   = 0,
        [int]$DocRefsFound        = 0,
        [int]$FilesCreated        = 0,
        [int]$FilesModified       = 0,
        [double]$DocsGroundedPct  = 0,
        [int]$RetryCount          = 0,
        [string[]]$Errors         = @()
    )

    return @{
        MonkeyName        = $MonkeyName
        Duration          = if ($Duration) { $Duration.ToString('hh\:mm\:ss') } else { '00:00:00' }
        DurationSeconds   = if ($Duration) { [int]$Duration.TotalSeconds } else { 0 }
        Model             = $Model
        ExitStatus        = $ExitStatus
        QuestionsAsked    = $QuestionsAsked
        QuestionsAnswered = $QuestionsAnswered
        DocRefsFound      = $DocRefsFound
        FilesCreated      = $FilesCreated
        FilesModified     = $FilesModified
        DocsGroundedPct   = $DocsGroundedPct
        RetryCount        = $RetryCount
        Errors            = $Errors
        Timestamp         = (Get-Date).ToString('o')
    }
}

# ─────────────────────────────────────────────
# Region: Agent-Mode Invocation
# ─────────────────────────────────────────────

function Start-AgentMonkey {
    <#
    .SYNOPSIS
        Launches copilot in agent mode (autonomous, multi-hour) with a prompt file.
        Used by Playbook and Curious George.
    .RETURNS
        Hashtable: @{ Success; Output; Duration; SharePath }
    #>
    param(
        [Parameter(Mandatory)][string]$PromptText,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [string]$ModelName,
        [int]$Timeout = 7200,   # 2h default for agent mode
        [string]$SharePath
    )

    $copilotArgs = @("--prompt", $PromptText, "--allow-all", "--autopilot", "--no-ask-user")
    if ($ModelName) { $copilotArgs += @("--model", $ModelName) }
    if ($SharePath) { $copilotArgs += @("--share=$SharePath") }

    $startTime = Get-Date

    $job = Start-Job -ScriptBlock {
        param($wd, $args_)
        Set-Location $wd
        $output = & copilot @args_ 2>&1
        @{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String).Trim() }
    } -ArgumentList $WorkingDirectory, $copilotArgs

    $completed = $job | Wait-Job -Timeout $Timeout
    $elapsed = (Get-Date) - $startTime

    if (-not $completed) {
        $job | Stop-Job -ErrorAction SilentlyContinue
        $partialOutput = try { $job | Receive-Job -ErrorAction SilentlyContinue | ForEach-Object { $_.Output } } catch { '' }
        $job | Remove-Job -Force -ErrorAction SilentlyContinue
        return @{
            Success   = $false
            Output    = $partialOutput
            Error     = "TIMEOUT after $($Timeout)s"
            Duration  = $elapsed
            SharePath = $SharePath
        }
    }

    $jobResult = $job | Receive-Job
    $job | Remove-Job -Force -ErrorAction SilentlyContinue

    return @{
        Success   = ($jobResult.ExitCode -eq 0 -or $null -eq $jobResult.ExitCode)
        Output    = $jobResult.Output
        Error     = if ($jobResult.ExitCode -ne 0) { "Exit code $($jobResult.ExitCode)" } else { $null }
        Duration  = $elapsed
        SharePath = $SharePath
    }
}

function Read-AgentStatus {
    <#
    .SYNOPSIS
        Parses machine-readable MONKEY_STATUS block from agent-mode output.
    .RETURNS
        Hashtable with parsed status fields, or $null if no block found.
    #>
    param([string]$Output)

    if (-not $Output) { return $null }

    $status = @{}
    $patterns = @{
        'Status'         = 'MONKEY_STATUS:\s*(SUCCESS|PARTIAL|FAILED)'
        'DocsCreated'    = 'DOCS_CREATED:\s*(\d+)'
        'DocsUpdated'    = 'DOCS_UPDATED:\s*(\d+)'
        'QuestionsAsked' = 'QUESTIONS_ASKED:\s*(\d+)'
        'GapsFound'      = 'GAPS_FOUND:\s*(\d+)'
        'GapsFixed'      = 'GAPS_FIXED:\s*(\d+)'
    }

    foreach ($key in $patterns.Keys) {
        $m = [regex]::Match($Output, $patterns[$key])
        if ($m.Success) {
            $val = $m.Groups[1].Value
            $status[$key] = if ($val -match '^\d+$') { [int]$val } else { $val }
        }
    }

    if ($status.Count -eq 0) { return $null }
    return $status
}

# ─────────────────────────────────────────────
# Region: Unified Input Wizard (Get-ArmyConfig)
# ─────────────────────────────────────────────

# Monkey pack definitions
$script:MonkeyPacks = @{
    'audit'      = @('rafiki', 'abu', 'mojo-jojo')
    'security'   = @('mojo-jojo', 'king-louie')
    'docs'       = @('playbook', 'rafiki', 'abu', 'marcel')
    'full'       = @('playbook', 'rafiki', 'abu', 'diddy-kong', 'king-louie', 'mojo-jojo', 'donkey-kong', 'marcel', 'curious-george')
    'autonomous' = @('playbook', 'curious-george')
    'quick'      = @('rafiki', 'abu')
}

$script:AllMonkeys = @(
    @{ Id = 'playbook';       Name = 'Playbook';       Emoji = '📋'; Mode = 'agent';  Phase = 0; Desc = 'Generate knowledge layer foundation' }
    @{ Id = 'rafiki';         Name = 'Rafiki';         Emoji = '🐒'; Mode = 'prompt'; Phase = 1; Desc = 'Read code entry points, broad questions' }
    @{ Id = 'abu';            Name = 'Abu';            Emoji = '🐵'; Mode = 'prompt'; Phase = 2; Desc = 'Find and fill documentation gaps' }
    @{ Id = 'diddy-kong';     Name = 'Diddy Kong';     Emoji = '🐒'; Mode = 'prompt'; Phase = 3; Desc = 'Map architecture & dependencies' }
    @{ Id = 'king-louie';     Name = 'King Louie';     Emoji = '👑'; Mode = 'prompt'; Phase = 4; Desc = 'Validate API contracts vs code' }
    @{ Id = 'mojo-jojo';      Name = 'Mojo Jojo';      Emoji = '🦹'; Mode = 'prompt'; Phase = 5; Desc = 'Security, edge cases, crash patterns' }
    @{ Id = 'donkey-kong';    Name = 'Donkey Kong';     Emoji = '🦍'; Mode = 'prompt'; Phase = 6; Desc = 'Find untested code & coverage gaps' }
    @{ Id = 'marcel';         Name = 'Marcel';          Emoji = '🙈'; Mode = 'prompt'; Phase = 7; Desc = 'Detect stale/dead doc references' }
    @{ Id = 'curious-george'; Name = 'Curious George';  Emoji = '🐵'; Mode = 'agent';  Phase = 8; Desc = 'Deep 3-pass autonomous audit' }
)

function Get-ArmyConfig {
    <#
    .SYNOPSIS
        Unified input wizard. Collects ALL inputs upfront for the entire run.
        Returns a config hashtable consumed by the orchestrator and passed to each monkey.
        When -NonInteractive is set, uses defaults + explicit params (for CI/CD).
    #>
    param(
        # ── Pre-filled values (skip prompts for these) ──
        [string]$RepoUrl,
        [string]$RepoPath,
        [string]$ClonePath,
        [string]$BaseBranch,
        [string]$BranchName,
        [switch]$UseBaseBranch,
        [string]$Model,
        [string]$Pack,
        [string[]]$Monkeys,
        [string]$CommitMode,         # 'dry-run' | 'commit' | 'stage'
        [switch]$CreatePR,
        [string]$GitProvider,        # 'ado' | 'github' | 'gitlab' | 'git'
        [int]$QuestionsPerEntry,
        [int]$QuestionsPerGap,
        [int]$QuestionsPerFile,
        [string[]]$TargetAgents,     # AI agents to score: copilot, cursor, claude, coderabbit, aider, windsurf
        # ── Curious George specifics ──
        [int]$GeorgeQuestionsPerDomain,
        [string]$GeorgeFocusArea,
        [string]$GeorgeDifficulty,
        [int]$GeorgeMaxSkip,
        [string]$GeorgeFixMode,
        [string]$GeorgeDiscoveryMode,
        # ── Behavior ──
        [switch]$NonInteractive
    )

    $config = @{}

    # ═══════════════════════════════════════════
    # GROUP 1: REPOSITORY
    # ═══════════════════════════════════════════
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Magenta
    Write-Host "  ║  🐒 MONKEY ARMY — Mission Briefing       ║" -ForegroundColor Magenta
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Magenta
    Write-Host ""

    # Q1: Repo source
    if ($RepoPath) {
        $config.RepoPath = $RepoPath
        $config.RepoUrl  = $null
        Write-Step "Repo: $RepoPath (local)" "OK"
    }
    elseif ($RepoUrl) {
        $config.RepoUrl = $RepoUrl
        if (-not $ClonePath) {
            if ($NonInteractive) { $ClonePath = ".\monkey-workspace" }
            else {
                Write-Host "  📁 Where should we clone?" -ForegroundColor Cyan
                $ClonePath = Read-Host "     Clone path (default: .\monkey-workspace)"
                if ([string]::IsNullOrWhiteSpace($ClonePath)) { $ClonePath = ".\monkey-workspace" }
            }
        }
        $config.ClonePath = $ClonePath
        Write-Step "Repo: $RepoUrl → $ClonePath" "OK"
    }
    else {
        if ($NonInteractive) { throw "Either -RepoUrl or -RepoPath required in non-interactive mode." }
        Write-Host "  📦 Repository source:" -ForegroundColor Cyan
        Write-Host "    [1] Local path (already cloned)" -ForegroundColor DarkGray
        Write-Host "    [2] Git URL (will clone)" -ForegroundColor DarkGray
        $choice = Read-Host "     Choose (default: 1)"
        if ($choice -eq '2') {
            $config.RepoUrl = Read-Host "     Git URL"
            $cp = Read-Host "     Clone path (default: .\monkey-workspace)"
            $config.ClonePath = if ([string]::IsNullOrWhiteSpace($cp)) { ".\monkey-workspace" } else { $cp }
        }
        else {
            $config.RepoPath = Read-Host "     Path to repo"
            if (-not (Test-Path $config.RepoPath)) { throw "Path '$($config.RepoPath)' not found." }
        }
    }

    # Q2: Base branch
    if (-not $BaseBranch -and -not $NonInteractive) {
        $detectDir = if ($config.RepoPath) { $config.RepoPath } else { $null }
        if ($detectDir -and (Test-Path $detectDir)) {
            Push-Location $detectDir
            $branches = @(& git --no-pager branch -r 2>&1 | ForEach-Object { $_.Trim() -replace '^origin/', '' } | Where-Object { $_ -and $_ -notmatch 'HEAD' } | Select-Object -First 15)
            Pop-Location
            if ($branches.Count -gt 0) {
                Write-Host "  🌿 Remote branches:" -ForegroundColor Cyan
                for ($i = 0; $i -lt $branches.Count; $i++) {
                    Write-Host "    [$i] $($branches[$i])" -ForegroundColor DarkGray
                }
            }
        }
        $input_ = Read-Host "     Base branch (default: main)"
        if ([string]::IsNullOrWhiteSpace($input_)) { $BaseBranch = "main" }
        elseif ($branches -and $input_ -match '^\d+$' -and [int]$input_ -lt $branches.Count) {
            $BaseBranch = $branches[[int]$input_]
        }
        else { $BaseBranch = $input_ }
    }
    $config.BaseBranch = if ($BaseBranch) { $BaseBranch } else { "main" }
    Write-Step "Base branch: $($config.BaseBranch)" "OK"

    # ═══════════════════════════════════════════
    # GROUP 2: EXECUTION
    # ═══════════════════════════════════════════
    Write-Host ""

    # Q3: Pack / monkey selection
    if ($Pack) {
        if (-not $script:MonkeyPacks.ContainsKey($Pack)) {
            throw "Unknown pack '$Pack'. Available: $($script:MonkeyPacks.Keys -join ', ')"
        }
        $config.SelectedMonkeys = $script:MonkeyPacks[$Pack]
        $config.Pack = $Pack
    }
    elseif ($Monkeys) {
        $config.SelectedMonkeys = $Monkeys
        $config.Pack = 'custom'
    }
    else {
        if ($NonInteractive) {
            $config.SelectedMonkeys = $script:MonkeyPacks['full']
            $config.Pack = 'full'
        }
        else {
            Write-Host "  🐒 Select monkey pack:" -ForegroundColor Cyan
            $packNames = @($script:MonkeyPacks.Keys | Sort-Object)
            for ($i = 0; $i -lt $packNames.Count; $i++) {
                $pName = $packNames[$i]
                $pMonkeys = $script:MonkeyPacks[$pName] -join ', '
                Write-Host "    [$($i+1)] $pName — $pMonkeys" -ForegroundColor DarkGray
            }
            Write-Host "    [$($packNames.Count+1)] custom (pick individual monkeys)" -ForegroundColor DarkGray
            $packChoice = Read-Host "     Choose (default: full)"

            if ($packChoice -match '^\d+$' -and [int]$packChoice -le $packNames.Count) {
                $config.Pack = $packNames[[int]$packChoice - 1]
                $config.SelectedMonkeys = $script:MonkeyPacks[$config.Pack]
            }
            elseif ($packChoice -eq [string]($packNames.Count + 1)) {
                Write-Host "  Available monkeys:" -ForegroundColor Cyan
                foreach ($m in $script:AllMonkeys) {
                    Write-Host "    $($m.Emoji) $($m.Id) — $($m.Desc)" -ForegroundColor DarkGray
                }
                $customInput = Read-Host "     Enter monkey IDs (comma-separated)"
                $config.SelectedMonkeys = @($customInput -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $config.Pack = 'custom'
            }
            else {
                $config.Pack = 'full'
                $config.SelectedMonkeys = $script:MonkeyPacks['full']
            }
        }
    }
    $monkeyList = $config.SelectedMonkeys -join ', '
    Write-Step "Pack: $($config.Pack) → [$monkeyList]" "OK"

    # Q4: Branch strategy
    if (-not $UseBaseBranch -and -not $BranchName) {
        if ($NonInteractive) { $BranchName = "monkey-army/$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
        else {
            Write-Host "  🌿 Branch strategy:" -ForegroundColor Cyan
            Write-Host "    [1] Create new branch (recommended)" -ForegroundColor DarkGray
            Write-Host "    [2] Work on '$($config.BaseBranch)' directly" -ForegroundColor DarkGray
            $brChoice = Read-Host "     Choose (default: 1)"
            if ($brChoice -eq '2') { $UseBaseBranch = [switch]::new($true) }
            else {
                $customBr = Read-Host "     Branch name (default: monkey-army/<timestamp>)"
                $BranchName = if ([string]::IsNullOrWhiteSpace($customBr)) {
                    "monkey-army/$(Get-Date -Format 'yyyyMMdd-HHmmss')"
                } else { $customBr }
            }
        }
    }
    $config.UseBaseBranch = [bool]$UseBaseBranch
    $config.BranchName = $BranchName
    Write-Step "Branch: $(if ($UseBaseBranch) { $config.BaseBranch } else { $BranchName })" "OK"

    # Q5: Commit mode
    if (-not $CommitMode) {
        if ($NonInteractive) { $CommitMode = 'commit' }
        else {
            Write-Host "  💾 Commit mode:" -ForegroundColor Cyan
            Write-Host "    [1] commit — auto-commit changes" -ForegroundColor DarkGray
            Write-Host "    [2] dry-run — stage only, don't commit" -ForegroundColor DarkGray
            Write-Host "    [3] stage — git add, no commit" -ForegroundColor DarkGray
            $cmChoice = Read-Host "     Choose (default: 1)"
            $CommitMode = switch ($cmChoice) {
                '2' { 'dry-run' }
                '3' { 'stage' }
                default { 'commit' }
            }
        }
    }
    $config.CommitMode = $CommitMode
    Write-Step "Commit mode: $CommitMode" "OK"

    # Q6: Create PR?
    if (-not $PSBoundParameters.ContainsKey('CreatePR')) {
        if ($NonInteractive) { $CreatePR = [switch]::new($false) }
        elseif ($CommitMode -eq 'commit' -and -not $UseBaseBranch) {
            $prChoice = Read-Host "  📬 Create pull request when done? [Y/n]"
            $CreatePR = [switch]::new($prChoice -notmatch '^[Nn]')
        }
    }
    $config.CreatePR = [bool]$CreatePR
    if ($config.CreatePR) { Write-Step "PR: will create when done" "OK" }

    # Q7: Git provider
    if (-not $GitProvider) {
        $remoteUrl = if ($config.RepoUrl) { $config.RepoUrl }
        elseif ($config.RepoPath -and (Test-Path $config.RepoPath)) {
            Push-Location $config.RepoPath
            $u = & git --no-pager remote get-url origin 2>&1
            Pop-Location
            if ($LASTEXITCODE -eq 0) { $u } else { '' }
        } else { '' }
        $config.GitProvider = Get-GitProvider -RemoteUrl $remoteUrl
    }
    else {
        $config.GitProvider = $GitProvider
    }
    Write-Step "Git provider: $($config.GitProvider)" "OK"

    # ═══════════════════════════════════════════
    # GROUP 3: MODEL
    # ═══════════════════════════════════════════
    Write-Host ""

    $config['Model'] = $null  # Initialize — will auto-detect if not set
    if ($Model) {
        $config['Model'] = $Model
    }
    elseif (-not $NonInteractive) {
        Write-Host "  🤖 Model preference:" -ForegroundColor Cyan
        Write-Host "    [1] Auto-detect (probe best available)" -ForegroundColor DarkGray
        Write-Host "    [2] Specify model name" -ForegroundColor DarkGray
        $mChoice = Read-Host "     Choose (default: 1)"
        if ($mChoice -eq '2') {
            $config['Model'] = Read-Host "     Model name"
        }
        else {
            $config['Model'] = $null  # Will auto-detect during setup
        }
    }
    Write-Step "Model: $(if ($config['Model']) { $config['Model'] } else { 'auto-detect' })" "OK"

    # ═══════════════════════════════════════════
    # GROUP 4: MONKEY TUNING
    # ═══════════════════════════════════════════
    Write-Host ""

    $hasPromptMonkeys = @($config.SelectedMonkeys | Where-Object { $_ -notin @('playbook', 'curious-george') })

    # Only ask tuning questions if relevant monkeys are selected
    if ($hasPromptMonkeys.Count -gt 0) {
        if ($QuestionsPerEntry -gt 0) {
            $config.QuestionsPerEntry = $QuestionsPerEntry
        }
        elseif ('rafiki' -in $config.SelectedMonkeys -and -not $NonInteractive) {
            $qpe = Read-Host "  🐒 Rafiki: questions per entry point (default: 10)"
            $config.QuestionsPerEntry = if ($qpe -match '^\d+$') { [int]$qpe } else { 10 }
        }
        else { $config.QuestionsPerEntry = 10 }

        if ($QuestionsPerGap -gt 0) {
            $config.QuestionsPerGap = $QuestionsPerGap
        }
        elseif ('abu' -in $config.SelectedMonkeys -and -not $NonInteractive) {
            $qpg = Read-Host "  🐵 Abu: questions per doc gap (default: 5)"
            $config.QuestionsPerGap = if ($qpg -match '^\d+$') { [int]$qpg } else { 5 }
        }
        else { $config.QuestionsPerGap = 5 }

        if ($QuestionsPerFile -gt 0) {
            $config.QuestionsPerFile = $QuestionsPerFile
        }
        elseif ('mojo-jojo' -in $config.SelectedMonkeys -and -not $NonInteractive) {
            $qpf = Read-Host "  🦹 Mojo Jojo: questions per risky file (default: 5)"
            $config.QuestionsPerFile = if ($qpf -match '^\d+$') { [int]$qpf } else { 5 }
        }
        else { $config.QuestionsPerFile = 5 }

        Write-Step "Tuning: Rafiki=$($config.QuestionsPerEntry)/entry, Abu=$($config.QuestionsPerGap)/gap, Mojo=$($config.QuestionsPerFile)/file" "OK"
    }

    # ═══════════════════════════════════════════
    # GROUP 4b: AI AGENT TARGETS
    # ═══════════════════════════════════════════
    $knownAgents = @('copilot', 'cursor', 'claude', 'coderabbit', 'aider', 'windsurf')
    if ($TargetAgents -and $TargetAgents.Count -gt 0) {
        $config['TargetAgents'] = $TargetAgents
    }
    elseif (-not $NonInteractive) {
        Write-Host ""
        Write-Host "  🤖 Which AI agents does your team use? (for health scoring)" -ForegroundColor Cyan
        Write-Host "    Available: $($knownAgents -join ', ')" -ForegroundColor DarkGray
        Write-Host "    Enter comma-separated list, or press Enter for all" -ForegroundColor DarkGray
        $agentInput = Read-Host "     Agents"
        if ([string]::IsNullOrWhiteSpace($agentInput)) {
            $config['TargetAgents'] = $knownAgents
        } else {
            $config['TargetAgents'] = @($agentInput -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
        }
    }
    else {
        $config['TargetAgents'] = $knownAgents  # Default: all
    }
    Write-Step "AI targets: $($config['TargetAgents'] -join ', ')" "OK"

    # ═══════════════════════════════════════════
    # GROUP 5: CURIOUS GEORGE SETUP
    # (mirrors the 7 setup questions from the prompt)
    # ═══════════════════════════════════════════
    if ('curious-george' -in $config.SelectedMonkeys) {
        Write-Host ""
        Write-Host "  🐵 Curious George — Setup Questions:" -ForegroundColor Yellow
        Write-Host "  (These pre-fill George's autonomous session)" -ForegroundColor DarkGray

        # CG-Q1: Questions per domain
        # Default: 10x the per-entry question count (George digs deeper)
        $georgeDefault = [Math]::Max(10, ($config.QuestionsPerEntry ?? 3) * 10)
        if ($GeorgeQuestionsPerDomain -gt 0) {
            $config.GeorgeQuestionsPerDomain = $GeorgeQuestionsPerDomain
        }
        elseif (-not $NonInteractive) {
            $gq = Read-Host "    1. Questions per domain? (default: $georgeDefault — 10x per-entry count)"
            $config.GeorgeQuestionsPerDomain = if ($gq -match '^\d+$') { [int]$gq } else { $georgeDefault }
        }
        else { $config.GeorgeQuestionsPerDomain = $georgeDefault }

        # CG-Q2: Focus area
        if ($PSBoundParameters.ContainsKey('GeorgeFocusArea')) {
            $config.GeorgeFocusArea = $GeorgeFocusArea
        }
        elseif (-not $NonInteractive) {
            $gf = Read-Host "    2. Focus area? (blank = all domains)"
            $config.GeorgeFocusArea = if ([string]::IsNullOrWhiteSpace($gf)) { '' } else { $gf }
        }
        else { $config.GeorgeFocusArea = '' }

        # CG-Q3: Difficulty
        if ($GeorgeDifficulty) {
            $config.GeorgeDifficulty = $GeorgeDifficulty
        }
        elseif (-not $NonInteractive) {
            Write-Host "    3. Difficulty:" -ForegroundColor DarkGray
            Write-Host "       [1] basic  [2] intermediate  [3] deep" -ForegroundColor DarkGray
            $gd = Read-Host "       Choose (default: deep)"
            $config.GeorgeDifficulty = switch ($gd) {
                '1' { 'basic' }
                '2' { 'intermediate' }
                default { 'deep' }
            }
        }
        else { $config.GeorgeDifficulty = 'deep' }

        # CG-Q4: Max consecutive covered before skip
        if ($GeorgeMaxSkip -gt 0) {
            $config.GeorgeMaxSkip = $GeorgeMaxSkip
        }
        elseif (-not $NonInteractive) {
            $gs = Read-Host "    4. Max consecutive covered before skipping domain? (default: 3)"
            $config.GeorgeMaxSkip = if ($gs -match '^\d+$') { [int]$gs } else { 3 }
        }
        else { $config.GeorgeMaxSkip = 3 }

        # CG-Q5: Auto-fix mode
        if ($GeorgeFixMode) {
            $config.GeorgeFixMode = $GeorgeFixMode
        }
        elseif (-not $NonInteractive) {
            Write-Host "    5. Auto-fix gaps?" -ForegroundColor DarkGray
            Write-Host "       [1] yes (edit docs)  [2] dry-run (report only)" -ForegroundColor DarkGray
            $gfm = Read-Host "       Choose (default: yes)"
            $config.GeorgeFixMode = if ($gfm -eq '2') { 'dry-run' } else { 'yes' }
        }
        else { $config.GeorgeFixMode = 'yes' }

        # CG-Q6: Discovery mode
        if ($GeorgeDiscoveryMode) {
            $config.GeorgeDiscoveryMode = $GeorgeDiscoveryMode
        }
        elseif (-not $NonInteractive) {
            Write-Host "    6. Discovery mode?" -ForegroundColor DarkGray
            Write-Host "       [1] full (find & create new docs)  [2] audit-only (existing docs)" -ForegroundColor DarkGray
            $gdm = Read-Host "       Choose (default: full)"
            $config.GeorgeDiscoveryMode = if ($gdm -eq '2') { 'audit-only' } else { 'full' }
        }
        else { $config.GeorgeDiscoveryMode = 'full' }

        Write-Step "George: $($config.GeorgeQuestionsPerDomain)q/domain, $($config.GeorgeDifficulty), fix=$($config.GeorgeFixMode), discovery=$($config.GeorgeDiscoveryMode)" "OK"
    }

    # ═══════════════════════════════════════════
    # SUMMARY
    # ═══════════════════════════════════════════
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════╗" -ForegroundColor Green
    Write-Host "  ║  ✅ Mission briefing complete!            ║" -ForegroundColor Green
    Write-Host "  ╚══════════════════════════════════════════╝" -ForegroundColor Green

    # Build ordered monkey list (sorted by phase)
    $orderedMonkeys = @()
    foreach ($m in $script:AllMonkeys) {
        if ($m.Id -in $config.SelectedMonkeys) {
            $orderedMonkeys += $m
        }
    }
    $config.OrderedMonkeys = $orderedMonkeys

    Write-Host ""
    Write-Host "  Execution order:" -ForegroundColor Cyan
    foreach ($m in $orderedMonkeys) {
        Write-Host "    Phase $($m.Phase): $($m.Emoji) $($m.Name) [$($m.Mode)]" -ForegroundColor DarkGray
    }
    Write-Host ""

    if (-not $NonInteractive) {
        $confirm = Read-Host "  🚀 Ready to deploy the army? [Y/n]"
        if ($confirm -match '^[Nn]') {
            throw "Mission aborted by user."
        }
    }

    return $config
}

function Get-MonkeyById {
    <#
    .SYNOPSIS
        Looks up monkey metadata by ID.
    #>
    param([Parameter(Mandatory)][string]$Id)
    return $script:AllMonkeys | Where-Object { $_.Id -eq $Id }
}

function Get-MonkeyPacks {
    <# Returns the pack definitions. #>
    return $script:MonkeyPacks
}

# Export all public functions
Export-ModuleMember -Function @(
    'Write-MonkeyBanner'
    'Write-Phase'
    'Write-Step'
    'Write-MonkeySummary'
    'Invoke-CopilotWithRetry'
    'Get-DocReferences'
    'Invoke-MonkeySetup'
    'Test-Preflight'
    'Test-CopilotInRepo'
    'Select-MonkeyModel'
    'Invoke-MonkeyCommit'
    'Invoke-MonkeyQuestions'
    'Save-MonkeyReport'
    'New-MonkeyResult'
    'Start-AgentMonkey'
    'Read-AgentStatus'
    'Get-ArmyConfig'
    'Get-MonkeyById'
    'Get-MonkeyPacks'
)
