<#
.SYNOPSIS
    Diddy Kong 🐒 — The Architecture Mapper (Monkey Army)

.DESCRIPTION
    Diddy Kong maps dependency graphs across codebases, detecting architectural issues like
    circular dependencies, orphan modules, layer violations, and hub modules (high coupling).
    Generates targeted questions via GitHub Copilot CLI to document component boundaries
    and dependency rules.

    Phase 1: Setup (shared — clone/branch/model/preflight)
    Phase 2: Discovery — Scans imports/dependencies across languages via git ls-files
    Phase 3: Question Generation — Copilot generates architecture questions per finding
    Phase 4: Question Execution (shared — copilot CLI with retry)
    Phase 5: Commit & Report (shared — git stage/commit + healing report)

    Part of the Monkey Army 🐒🐵 framework. Phase 3 in the army.

.PARAMETER RepoUrl
    Git repo URL to clone.

.PARAMETER ClonePath
    Local path for clone. Defaults to .\monkey-workspace

.PARAMETER RepoPath
    Path to an already-cloned local repo. Skips clone.

.PARAMETER BaseBranch
    Branch to pull latest from. If not provided, prompts the user.

.PARAMETER UseBaseBranch
    Work directly on the base branch instead of creating a new one.

.PARAMETER BranchName
    Working branch name. Defaults to diddy-kong/<timestamp>.

.PARAMETER Model
    Copilot model to use. If not specified, auto-probes best available.

.PARAMETER QuestionsPerFinding
    Number of questions per architectural finding. Default 3.

.PARAMETER DryRun
    Stage changes only, don't commit.

.PARAMETER Commit
    Auto-commit doc changes to the branch.

.PARAMETER MaxRetries
    Max retries per copilot call on capacity/transient errors. Default 3.

.PARAMETER RetryBaseDelay
    Base delay in seconds for exponential backoff. Default 30.

.PARAMETER CallTimeout
    Hard timeout in seconds per copilot -p call. Default 300 (5 min).

.PARAMETER ShowVerbose
    Show copilot output in real-time.

.EXAMPLE
    .\diddy-kong.ps1 -RepoPath "C:\myrepo" -DryRun -QuestionsPerFinding 3

.EXAMPLE
    .\diddy-kong.ps1 -RepoUrl "https://github.com/org/repo.git" -Commit -Model "claude-sonnet-4"
#>

param(
    [string]$RepoUrl,
    [string]$ClonePath = ".\monkey-workspace",
    [string]$RepoPath,
    [string]$BaseBranch,
    [switch]$UseBaseBranch,
    [string]$BranchName,
    [string]$Model,
    [int]$QuestionsPerFinding = 3,
    [switch]$DryRun,
    [switch]$Commit,
    [int]$MaxRetries = 3,
    [int]$RetryBaseDelay = 30,
    [int]$CallTimeout = 300,
    [switch]$ShowVerbose,

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

# ─────────────────────────────────────────────
# Region: Constants
# ─────────────────────────────────────────────

$script:MONKEY_NAME    = "Diddy Kong"
$script:MONKEY_EMOJI   = "🐒"
$script:MONKEY_VERSION = "1.0.0"
$script:MONKEY_TAGLINE = "The Architecture Mapper"
$script:OUTPUT_DIR     = ".monkey-output"

# Import/dependency patterns per language extension
$script:IMPORT_PATTERNS = @{
    '*.cs'   = @('using\s+([\w\.]+)', '#r\s+"([^"]+)"')
    '*.py'   = @('(?:from|import)\s+([\w\.]+)')
    '*.ts'   = @('(?:import|require)\s*\(?[''"`]([^''"`]+)')
    '*.js'   = @('(?:import|require)\s*\(?[''"`]([^''"`]+)')
    '*.java' = @('import\s+([\w\.]+)')
    '*.go'   = @('"([\w/\\.]+)"')
    '*.rb'   = @('require\s+[''"`]([^''"`]+)')
    '*.rs'   = @('use\s+([\w:]+)')
    '*.kt'   = @('import\s+([\w\.]+)')
    '*.php'  = @('use\s+([\w\\\\]+)')
}

# Exclude patterns for scanned paths
$script:EXCLUDE_REGEX = '[\\/](bin|obj|node_modules|vendor|\.git|dist|build|target|__pycache__|\.gradle|\.monkey-output|\.rafiki-output|\.abu-output|\.mojo-jojo-output)[\\/]'

# Hub module threshold — imported by more than this many files
$script:HUB_THRESHOLD = 10

# ─────────────────────────────────────────────
# Region: Phase 2 — Discovery
# ─────────────────────────────────────────────

function Get-TrackedFiles {
    <#
    .SYNOPSIS
        Returns tracked files from git ls-files, filtered to supported extensions.
    #>
    param([string]$WorkDir)

    $extensions = $script:IMPORT_PATTERNS.Keys | ForEach-Object { $_ -replace '^\*', '' }
    $allFiles = @()

    Push-Location $WorkDir
    try {
        $tracked = git ls-files 2>$null
        if (-not $tracked) { return @() }
        foreach ($f in $tracked) {
            $ext = [System.IO.Path]::GetExtension($f)
            if ($ext -and ($extensions -contains $ext)) {
                $fullPath = Join-Path $WorkDir $f
                if ($f -notmatch $script:EXCLUDE_REGEX -and (Test-Path $fullPath)) {
                    $allFiles += @{ RelPath = $f; FullPath = $fullPath; Extension = $ext }
                }
            }
        }
    }
    finally { Pop-Location }

    return $allFiles
}

function Build-DependencyGraph {
    <#
    .SYNOPSIS
        Scans tracked files for import statements and builds a dependency graph.
        Returns: graph (file→imports), reverse graph (module→importers), and file list.
    #>
    param([array]$Files, [string]$WorkDir)

    Write-Phase "PHASE 2" "Discovery — Building Dependency Graph ($($Files.Count) files)"

    $graph   = @{}   # file → list of imported modules
    $reverse = @{}   # module → list of files that import it
    $scanned = 0

    foreach ($file in $Files) {
        $scanned++
        if ($scanned % 100 -eq 0) {
            Write-Host "  📂 Scanned $scanned / $($Files.Count) files..." -ForegroundColor DarkGray
        }

        $globKey = "*$($file.Extension)"
        $patterns = $script:IMPORT_PATTERNS[$globKey]
        if (-not $patterns) { continue }

        try {
            $content = Get-Content $file.FullPath -Raw -ErrorAction Stop
            if (-not $content) { continue }
        }
        catch { continue }

        $imports = @()
        foreach ($pattern in $patterns) {
            $matches_ = [regex]::Matches($content, $pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
            foreach ($m in $matches_) {
                $dep = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $null }
                if ($dep -and $dep -notin $imports) {
                    $imports += $dep
                }
            }
        }

        if ($imports.Count -gt 0) {
            $graph[$file.RelPath] = $imports
            foreach ($dep in $imports) {
                if (-not $reverse.ContainsKey($dep)) { $reverse[$dep] = @() }
                $reverse[$dep] += $file.RelPath
            }
        }
    }

    Write-Step "Scanned $scanned files, $($graph.Count) have dependencies" "OK"
    return @{ Graph = $graph; Reverse = $reverse }
}

# ─────────────────────────────────────────────
# Region: Phase 2b — Architectural Analysis
# ─────────────────────────────────────────────

function Find-CircularDependencies {
    <#
    .SYNOPSIS
        DFS-based cycle detection on the dependency graph.
        Returns list of cycles found (each cycle is an array of file paths).
        Uses pre-built lookup tables for O(1) dependency resolution.
    #>
    param([hashtable]$Graph)

    # Build O(1) lookup: filename (without ext) → list of full paths
    $nameLookup = @{}
    foreach ($key in $Graph.Keys) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($key)
        if (-not $nameLookup.ContainsKey($baseName)) {
            $nameLookup[$baseName] = [System.Collections.Generic.List[string]]::new()
        }
        $nameLookup[$baseName].Add($key)
    }

    $visited  = @{}
    $recStack = @{}
    $cycles   = [System.Collections.Generic.List[object]]::new()
    $maxCycles = 50  # Cap to avoid runaway on huge graphs

    function Visit-Node {
        param([string]$Node, [System.Collections.ArrayList]$Path)

        if ($cycles.Count -ge $maxCycles) { return }

        $visited[$Node]  = $true
        $recStack[$Node] = $true
        [void]$Path.Add($Node)

        $deps = $Graph[$Node]
        if ($deps) {
            foreach ($dep in $deps) {
                if ($cycles.Count -ge $maxCycles) { break }

                # O(1) lookup: check if dep is a direct graph key or resolve by filename
                $targets = @()
                if ($Graph.ContainsKey($dep)) {
                    $targets = @($dep)
                } elseif ($nameLookup.ContainsKey($dep)) {
                    $targets = @($nameLookup[$dep])
                }

                foreach ($target in $targets) {
                    if ($recStack.ContainsKey($target) -and $recStack[$target]) {
                        $cycleStart = $Path.IndexOf($target)
                        if ($cycleStart -ge 0) {
                            $cycle = @($Path[$cycleStart..($Path.Count - 1)]) + @($target)
                            $cycles.Add($cycle)
                        }
                    }
                    elseif (-not $visited.ContainsKey($target)) {
                        Visit-Node -Node $target -Path $Path
                    }
                }
            }
        }

        $recStack[$Node] = $false
        $Path.RemoveAt($Path.Count - 1)
    }

    foreach ($node in $Graph.Keys) {
        if ($cycles.Count -ge $maxCycles) { break }
        if (-not $visited.ContainsKey($node)) {
            Visit-Node -Node $node -Path ([System.Collections.ArrayList]::new())
        }
    }

    return @($cycles)
}

function Find-OrphanModules {
    <#
    .SYNOPSIS
        Finds files that are never imported by any other file.
    #>
    param([hashtable]$Graph, [hashtable]$Reverse, [array]$AllFiles)

    $importedModules = $Reverse.Keys
    $orphans = @()

    foreach ($file in $AllFiles) {
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.RelPath)
        $isImported = $false
        foreach ($mod in $importedModules) {
            if ($mod -like "*$baseName*" -or $mod -eq $baseName) {
                $isImported = $true
                break
            }
        }
        # Entry points (controllers, main, app, index, program) are expected orphans
        if (-not $isImported -and $baseName -notmatch '(?i)^(main|app|index|program|startup|server|boot)$' -and
            $file.RelPath -notmatch '(?i)(controller|handler|endpoint|route|test|spec)') {
            $orphans += $file.RelPath
        }
    }

    return $orphans
}

function Find-HubModules {
    <#
    .SYNOPSIS
        Finds modules imported by more than HUB_THRESHOLD files.
    #>
    param([hashtable]$Reverse)

    $hubs = @()
    foreach ($mod in $Reverse.Keys) {
        $importerCount = $Reverse[$mod].Count
        if ($importerCount -gt $script:HUB_THRESHOLD) {
            $hubs += @{ Module = $mod; ImporterCount = $importerCount; Importers = $Reverse[$mod] }
        }
    }
    return @($hubs | Sort-Object { $_.ImporterCount } -Descending)
}

function Invoke-ArchAnalysis {
    <#
    .SYNOPSIS
        Runs all architectural checks and returns consolidated findings.
    #>
    param([hashtable]$DepData, [array]$AllFiles, [string]$OutputPath)

    Write-Phase "PHASE 2b" "Architecture Analysis — Detecting Issues"

    $findings = @()

    # 1. Circular dependencies
    Write-Step "Detecting circular dependencies..." "INFO"
    $cycles = Find-CircularDependencies -Graph $DepData.Graph
    foreach ($cycle in $cycles | Select-Object -First 20) {
        $findings += @{
            Type    = "CIRCULAR_DEPENDENCY"
            Severity = "HIGH"
            Files   = $cycle
            Detail  = "Cycle: $($cycle -join ' → ')"
        }
    }
    Write-Step "Found $($cycles.Count) circular dependency chain(s)" $(if ($cycles.Count -gt 0) { "WARN" } else { "OK" })

    # 2. Orphan modules
    Write-Step "Detecting orphan modules..." "INFO"
    $orphans = Find-OrphanModules -Graph $DepData.Graph -Reverse $DepData.Reverse -AllFiles $AllFiles
    foreach ($orphan in $orphans | Select-Object -First 50) {
        $findings += @{
            Type    = "ORPHAN_MODULE"
            Severity = "LOW"
            Files   = @($orphan)
            Detail  = "File '$orphan' is not imported by any other module"
        }
    }
    Write-Step "Found $($orphans.Count) orphan module(s)" $(if ($orphans.Count -gt 0) { "WARN" } else { "OK" })

    # 3. Hub modules (high coupling)
    Write-Step "Detecting hub modules (imported by >$($script:HUB_THRESHOLD) files)..." "INFO"
    $hubs = Find-HubModules -Reverse $DepData.Reverse
    foreach ($hub in $hubs) {
        $findings += @{
            Type    = "HUB_MODULE"
            Severity = "MEDIUM"
            Files   = @($hub.Module)
            Detail  = "Module '$($hub.Module)' is imported by $($hub.ImporterCount) files — high coupling"
        }
    }
    Write-Step "Found $($hubs.Count) hub module(s)" $(if ($hubs.Count -gt 0) { "WARN" } else { "OK" })

    # Display summary table
    Write-Host ""
    Write-Host "  ┌────────────────────────┬──────────┬───────┐" -ForegroundColor DarkGray
    Write-Host "  │ Finding Type           │ Severity │ Count │" -ForegroundColor DarkGray
    Write-Host "  ├────────────────────────┼──────────┼───────┤" -ForegroundColor DarkGray
    $grouped = $findings | Group-Object { $_.Type }
    foreach ($g in $grouped) {
        $sev = ($g.Group | Select-Object -First 1).Severity
        $sevColor = switch ($sev) { "HIGH" { "Red" } "MEDIUM" { "Yellow" } default { "DarkGray" } }
        Write-Host ("  │ {0,-22} │ " -f $g.Name) -ForegroundColor DarkGray -NoNewline
        Write-Host ("{0,-8}" -f $sev) -ForegroundColor $sevColor -NoNewline
        Write-Host (" │ {0,-5} │" -f $g.Count) -ForegroundColor DarkGray
    }
    Write-Host "  └────────────────────────┴──────────┴───────┘" -ForegroundColor DarkGray

    # Save findings to JSON
    $findingsPath = Join-Path $OutputPath "arch-findings.json"
    $findings | ConvertTo-Json -Depth 10 | Set-Content $findingsPath -Encoding UTF8
    Write-Step "Saved $($findings.Count) findings to arch-findings.json" "OK"

    return $findings
}

# ─────────────────────────────────────────────
# Region: Phase 3 — Question Generation
# ─────────────────────────────────────────────

function New-ArchQuestions {
    <#
    .SYNOPSIS
        For each architectural finding, asks copilot to generate targeted questions
        about component boundaries and dependency rules.
    #>
    param(
        [array]$Findings,
        [string]$WorkingDirectory
    )

    Write-Phase "PHASE 3" "Question Generation — $($Findings.Count) findings"

    $allQuestions   = @()
    $questionHashes = @{}
    $totalFindings  = $Findings.Count
    $currentF       = 0

    foreach ($finding in $Findings) {
        $currentF++
        $pct = [Math]::Round(($currentF / $totalFindings) * 100)
        Write-Progress -Activity "Generating architecture questions" -Status "$currentF/$totalFindings — $($finding.Type)" -PercentComplete $pct

        $typeLabel = switch ($finding.Type) {
            "CIRCULAR_DEPENDENCY" { "a circular dependency" }
            "ORPHAN_MODULE"       { "an orphan module (never imported)" }
            "HUB_MODULE"          { "a hub module with high coupling" }
            "LAYER_VIOLATION"     { "a layer violation" }
            default               { "an architectural issue" }
        }

        $filesStr = $finding.Files -join ", "
        $genPrompt = @"
I found $typeLabel in this codebase.
Files involved: $filesStr
Details: $($finding.Detail)

Generate exactly $QuestionsPerFinding targeted questions about this architectural concern.
Questions should trigger documentation of:
- Component boundaries and responsibilities
- Dependency rules and allowed/disallowed imports
- Refactoring strategies to resolve the issue
- Impact analysis if this issue is left unresolved

Each question must be specific to the actual files and patterns found.
Output ONLY a JSON array of strings. No explanation, no markdown fences.

Example: ["What are the component boundaries between ModuleA and ModuleB, and why does the circular dependency exist?"]
"@

        Write-Step "[$currentF/$totalFindings] Generating $QuestionsPerFinding questions for $($finding.Type) in $filesStr..." "INFO"

        $result = Invoke-CopilotWithRetry -Prompt $genPrompt -ModelName $script:SelectedModel `
            -WorkingDirectory $WorkingDirectory -Retries $MaxRetries `
            -BaseDelay $RetryBaseDelay -Timeout $CallTimeout

        if (-not $result.Success) {
            Write-Step "Failed to generate questions for $($finding.Type): $($result.Error)" "ERROR"
            continue
        }

        $questions = @()
        try {
            $output = $result.Output.Trim()
            if ($output -match '```(?:json)?\s*\n?([\s\S]*?)\n?\s*```') {
                $output = $Matches[1].Trim()
            }
            if ($output -match '\[[\s\S]*\]') {
                $jsonMatch = $Matches[0]
                $questions = @($jsonMatch | ConvertFrom-Json)
            }
        }
        catch {
            Write-Step "JSON parse failed for $($finding.Type). Falling back to line parsing." "WARN"
            $questions = @()
            $lines = $result.Output -split "`n"
            foreach ($line in $lines) {
                if ($line -match '^\s*\d+[\.\)]\s*(.+)') {
                    $questions += $Matches[1].Trim()
                }
            }
        }

        if ($questions.Count -eq 0) {
            Write-Step "No questions parsed for $($finding.Type)" "WARN"
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
                    EntryPoint = ($finding.Files | Select-Object -First 1)
                    Question   = $q
                    Category   = $finding.Type
                }
            }
        }

        Write-Step "Generated $($questions.Count) unique questions ($($allQuestions.Count) total)" "OK"
    }

    Write-Progress -Activity "Generating architecture questions" -Completed

    # Shuffle — HIGH severity first, then random
    $severityOrder = @{ "CIRCULAR_DEPENDENCY" = 0; "HUB_MODULE" = 1; "LAYER_VIOLATION" = 2; "ORPHAN_MODULE" = 3 }
    $allQuestions = @($allQuestions | Sort-Object { $severityOrder[$_.Category] }, { Get-Random })

    $questionsPath = Join-Path $script:OutputPath "questions.json"
    $allQuestions | ConvertTo-Json -Depth 5 | Set-Content $questionsPath -Encoding UTF8
    Write-Step "Saved $($allQuestions.Count) architecture questions to questions.json" "OK"

    return $allQuestions
}

# ─────────────────────────────────────────────
# Region: Main Orchestrator
# ─────────────────────────────────────────────

function Start-DiddyKong {
    $startTime = Get-Date

    try {
        # ── Mode split: standalone vs internal ──
        if (-not $Internal) {
            Write-MonkeyBanner -Name $script:MONKEY_NAME -Emoji $script:MONKEY_EMOJI -Version $script:MONKEY_VERSION -Tagline $script:MONKEY_TAGLINE
            Test-Preflight
            $setup = Invoke-MonkeySetup -RepoUrl $RepoUrl -ClonePath $ClonePath -RepoPath $RepoPath `
                -BaseBranch $BaseBranch -UseBaseBranch:$UseBaseBranch -BranchName $BranchName `
                -BranchPrefix "diddy-kong" -OutputDirName $script:OUTPUT_DIR
            $workDir = $setup.WorkDir
            $script:BranchName = $setup.Branch
            $script:OutputPath = $setup.OutputPath
            $script:SelectedModel = Select-MonkeyModel -UserModel $Model -WorkingDirectory $workDir
            Test-CopilotInRepo -WorkingDirectory $workDir
        }
        else {
            Write-Phase "DIDDY KONG" "Running in internal mode (orchestrated)"
            $workDir = $InternalRepoPath
            $script:SelectedModel = $InternalModel
            $script:OutputPath = $InternalOutputPath
            $script:BranchName = ''
            if (-not (Test-Path $script:OutputPath)) { New-Item -ItemType Directory -Path $script:OutputPath -Force | Out-Null }
            New-Item -ItemType Directory -Path (Join-Path $script:OutputPath "session-logs") -Force | Out-Null
        }

        # Phase 2: Discovery — scan files and build dependency graph
        $trackedFiles = Get-TrackedFiles -WorkDir $workDir
        if ($trackedFiles.Count -eq 0) {
            Write-Step "No supported source files found via git ls-files" "ERROR"
            throw "No source files discovered."
        }
        Write-Step "Found $($trackedFiles.Count) tracked source files" "OK"

        $depData = Build-DependencyGraph -Files $trackedFiles -WorkDir $workDir

        # Phase 2b: Architectural analysis
        $findings = Invoke-ArchAnalysis -DepData $depData -AllFiles $trackedFiles -OutputPath $script:OutputPath

        if ($findings.Count -eq 0) {
            Write-Step "No architectural issues found! 🎉" "OK"
            $duration = (Get-Date) - $startTime
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                -Model $script:SelectedModel -ExitStatus 'SUCCESS' -QuestionsAsked 0 -QuestionsAnswered 0
        }

        # Phase 3: Question generation
        $questions = New-ArchQuestions -Findings $findings -WorkingDirectory $workDir

        if ($questions.Count -eq 0) {
            Write-Step "No questions generated. Check findings." "WARN"
            $duration = (Get-Date) - $startTime
            return New-MonkeyResult -MonkeyName $script:MONKEY_NAME -Duration $duration `
                -Model $script:SelectedModel -ExitStatus 'SUCCESS' -QuestionsAsked 0 -QuestionsAnswered 0
        }

        # Phase 4: Execution (shared)
        $execStats = Invoke-MonkeyQuestions -Questions $questions -WorkingDirectory $workDir `
            -OutputPath $script:OutputPath -ModelName $script:SelectedModel -MonkeyEmoji $script:MONKEY_EMOJI `
            -MaxRetries $MaxRetries -RetryBaseDelay $RetryBaseDelay -CallTimeout $CallTimeout -ShowVerbose:$ShowVerbose

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

        $runStats = @{
            "01_FilesScanned"       = $trackedFiles.Count
            "02_DepsInGraph"        = $depData.Graph.Count
            "03_FindingsDetected"   = $findings.Count
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
        Write-Host "  $($script:MONKEY_EMOJI) Diddy Kong complete!" -ForegroundColor Green

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

Start-DiddyKong
