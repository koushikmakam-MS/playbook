<#
.SYNOPSIS
    Doc Health Scorer — Measures repository documentation health before and after monkey runs.
.DESCRIPTION
    Produces a 0-100 score across 5 categories + optional Monkey Army bonus.
    Generic — works on any repo, any language.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════
# HELPERS
# ═══════════════════════════════════════════════════════════════

function Get-RepoFiles {
    param([string]$RepoPath)
    $exclude = @('node_modules', 'vendor', '.git', 'bin', 'obj', '.monkey-output', '__pycache__', 'dist', 'build', '.next', 'target', 'packages')
    $allFiles = git -C $RepoPath ls-files 2>$null
    if (-not $allFiles) { $allFiles = Get-ChildItem $RepoPath -Recurse -File | ForEach-Object { $_.FullName.Replace("$RepoPath\", '').Replace('\', '/') } }
    $filtered = @($allFiles | Where-Object {
        $path = $_
        $skip = $false
        foreach ($ex in $exclude) { if ($path -match "(^|/)$ex/") { $skip = $true; break } }
        -not $skip
    })
    return $filtered
}

function Get-SourceFiles {
    param([string[]]$Files)
    $sourceExts = @('.cs', '.py', '.js', '.ts', '.java', '.go', '.rb', '.php', '.kt', '.rs', '.swift', '.cpp', '.c', '.h')
    @($Files | Where-Object { $ext = [IO.Path]::GetExtension($_); $sourceExts -contains $ext })
}

function Get-DocFiles {
    param([string[]]$Files)
    @($Files | Where-Object { $_ -match '\.(md|rst|txt|adoc)$' -and $_ -notmatch '(LICENSE|CHANGELOG|CHANGES|HISTORY|node_modules)' })
}

function Get-TestFiles {
    param([string[]]$Files)
    @($Files | Where-Object { $_ -match '(test|spec|_test|_spec|Tests?\.cs|\.test\.|\.spec\.)' -and $_ -match '\.(cs|py|js|ts|java|go|rb|php|kt|rs)$' })
}

function Get-FileContent {
    param([string]$RepoPath, [string]$RelPath, [int]$MaxBytes = 50000)
    $fullPath = Join-Path $RepoPath $RelPath
    if (Test-Path $fullPath) {
        $content = Get-Content $fullPath -Raw -ErrorAction SilentlyContinue
        if ($content -and $content.Length -gt $MaxBytes) { $content = $content.Substring(0, $MaxBytes) }
        return $content
    }
    return $null
}

function Get-GradeFromScore {
    param([int]$Score, [int]$Max = 100)
    $pct = [Math]::Round(($Score / $Max) * 100)
    if     ($pct -ge 90) { return 'A' }
    elseif ($pct -ge 75) { return 'B' }
    elseif ($pct -ge 60) { return 'C' }
    elseif ($pct -ge 45) { return 'D' }
    else                 { return 'F' }
}

# ═══════════════════════════════════════════════════════════════
# CATEGORY 1: CODE DOCUMENTATION (20 pts)
# ═══════════════════════════════════════════════════════════════

function Measure-CodeDocumentation {
    param([string]$RepoPath, [string[]]$AllFiles, [string[]]$SourceFiles)

    $score = 0
    $details = @{}

    # README exists and is substantial (5pts)
    $readme = $AllFiles | Where-Object { $_ -match '^README\.(md|rst|txt|adoc)$' } | Select-Object -First 1
    if ($readme) {
        $content = Get-FileContent -RepoPath $RepoPath -RelPath $readme
        if ($content -and $content.Length -gt 1000) {
            $score += 5; $details['README'] = "✅ Found ($([Math]::Round($content.Length/1KB,1))KB)"
        } elseif ($content) {
            $score += 2; $details['README'] = "⚠️ Exists but thin ($($content.Length) bytes)"
        } else {
            $details['README'] = '❌ Empty'
        }
    } else {
        $details['README'] = '❌ Not found'
    }

    # Build/test/setup docs (5pts)
    $setupSignals = @(
        ($AllFiles | Where-Object { $_ -match '(CONTRIBUTING|DEVELOPMENT|SETUP|INSTALL)\.(md|rst|txt)' } | Measure-Object).Count
        (($readme) -and (Get-FileContent -RepoPath $RepoPath -RelPath $readme) -match '(?i)(install|setup|build|getting.started|prerequisites|how.to.run)')
        ($AllFiles | Where-Object { $_ -match '(Makefile|Dockerfile|docker-compose|Taskfile|justfile)' } | Measure-Object).Count
    )
    $setupHits = @($setupSignals | Where-Object { $_ }).Count
    $setupScore = [Math]::Min(5, $setupHits)
    $score += $setupScore
    $details['BuildTestDocs'] = "$setupScore/5 setup signals found"

    # Entry points with doc comments (10pts)
    $entryPointPatterns = @(
        '(?m)^\s*\[(Http(Get|Post|Put|Delete|Patch)|Route|ApiController)\]'   # C# controllers
        '(?m)^\s*(export\s+)?(async\s+)?function\s+\w+'                       # JS/TS
        '(?m)^\s*def\s+\w+\s*\('                                              # Python
        '(?m)^\s*func\s+\w+\s*\('                                             # Go
        '(?m)^\s*(public|private|protected)\s+.*\s+\w+\s*\('                  # Java/C#
    )
    $docCommentPatterns = @('///\s*<summary>', '/\*\*', '"""', "'''", '///')

    $sampledFiles = @($SourceFiles | Sort-Object | Select-Object -First ([Math]::Min(50, $SourceFiles.Count)))
    $documented = 0; $total = 0
    foreach ($f in $sampledFiles) {
        $content = Get-FileContent -RepoPath $RepoPath -RelPath $f
        if (-not $content) { continue }
        $hasEntry = $false
        foreach ($pat in $entryPointPatterns) {
            if ($content -match $pat) { $hasEntry = $true; break }
        }
        if ($hasEntry) {
            $total++
            foreach ($dp in $docCommentPatterns) {
                if ($content -match $dp) { $documented++; break }
            }
        }
    }
    $docRatio = if ($total -gt 0) { $documented / $total } else { 0 }
    $entryPts = [Math]::Min(10, [Math]::Round($docRatio * 10))
    $score += $entryPts
    $details['EntryPointDocs'] = "$documented/$total sampled files with doc comments ($entryPts/10 pts)"

    return @{ Score = $score; Max = 20; Details = $details }
}

# ═══════════════════════════════════════════════════════════════
# CATEGORY 2: DOC QUALITY (20 pts)
# ═══════════════════════════════════════════════════════════════

function Measure-DocQuality {
    param([string]$RepoPath, [string[]]$AllFiles, [string[]]$DocFiles)

    $score = 20  # Start at max, deduct for issues
    $details = @{}

    # Dead references — check file paths in docs (deduct up to 8pts, ratio-based)
    $cachedFiles = @{}; foreach ($f in $AllFiles) { $cachedFiles[$f] = $true }
    $deadRefs = 0; $checkedRefs = 0
    $sampledDocs = @($DocFiles | Sort-Object | Select-Object -First ([Math]::Min(30, $DocFiles.Count)))
    foreach ($doc in $sampledDocs) {
        $content = Get-FileContent -RepoPath $RepoPath -RelPath $doc
        if (-not $content) { continue }
        $refs = [regex]::Matches($content, '\[.*?\]\(((?!http)[^\)]+)\)')
        foreach ($ref in $refs) {
            $checkedRefs++
            $refPath = $ref.Groups[1].Value -replace '#.*$', '' -replace '^\.\/', ''
            $docDir = [IO.Path]::GetDirectoryName($doc) -replace '\\', '/'
            $resolved = if ($refPath -match '^\.\.') { "$docDir/$refPath" } else { $refPath }
            $resolved = $resolved -replace '\\', '/'
            if (-not $cachedFiles.ContainsKey($resolved) -and -not $cachedFiles.ContainsKey($refPath)) {
                $deadRefs++
            }
            if ($checkedRefs -ge 200) { break }
        }
        if ($checkedRefs -ge 200) { break }
    }
    # Proportional: deduct based on dead/total ratio (not absolute count)
    $deadRatio = if ($checkedRefs -gt 0) { $deadRefs / $checkedRefs } else { 0 }
    $deadDeduct = [Math]::Min(8, [Math]::Round($deadRatio * 16))  # 50% dead = -8pts
    $score -= $deadDeduct
    $pctDead = [Math]::Round($deadRatio * 100)
    $details['DeadRefs'] = "$deadRefs/$checkedRefs refs dead ($pctDead%) (-$deadDeduct pts)"

    # Doc freshness vs code — compare timestamps (deduct up to 7pts)
    $staleCount = 0
    foreach ($doc in $sampledDocs) {
        $docPath = Join-Path $RepoPath $doc
        $docDate = git -C $RepoPath log -1 --format="%aI" -- $doc 2>$null
        if ($docDate) {
            $docAge = (Get-Date) - [DateTime]::Parse($docDate)
            # Find related source files (same directory or referenced)
            $docDir = [IO.Path]::GetDirectoryName($doc) -replace '\\', '/'
            $relatedCode = @($AllFiles | Where-Object { $_ -like "$docDir/*" -and $_ -match '\.(cs|py|js|ts|java|go)$' } | Select-Object -First 3)
            foreach ($code in $relatedCode) {
                $codeDate = git -C $RepoPath log -1 --format="%aI" -- $code 2>$null
                if ($codeDate) {
                    $codeAge = (Get-Date) - [DateTime]::Parse($codeDate)
                    if ($codeAge.TotalDays -lt ($docAge.TotalDays - 30)) {
                        $staleCount++; break  # Code changed significantly after doc
                    }
                }
            }
        }
    }
    $staleDeduct = [Math]::Min(7, [Math]::Round($staleCount * 1.5))
    $score -= $staleDeduct
    $details['StaleDocs'] = "$staleCount docs older than related code (-$staleDeduct pts)"

    # Navigation / Index quality (deduct up to 5pts)
    $navSignals = 0
    $indexFiles = @($AllFiles | Where-Object { $_ -match '(docs/.*index|docs/.*README|table.of.contents|TOC\.md|SUMMARY\.md|doc_registry)' })
    if ($indexFiles.Count -gt 0) { $navSignals++ }
    if ($readme = $AllFiles | Where-Object { $_ -match '^README\.(md|rst)$' } | Select-Object -First 1) {
        $content = Get-FileContent -RepoPath $RepoPath -RelPath $readme
        if ($content -match '\[.*\]\(docs/') { $navSignals++ }  # Links to docs
        if ($content -match '#{2,}.*table of contents|#{2,}.*documentation' ) { $navSignals++ }
    }
    $navDeduct = [Math]::Max(0, 5 - ($navSignals * 2))
    $score -= $navDeduct
    $details['Navigation'] = "$navSignals navigation signals (-$navDeduct pts)"

    $score = [Math]::Max(0, $score)
    return @{ Score = $score; Max = 20; Details = $details }
}

# ═══════════════════════════════════════════════════════════════
# CATEGORY 3: AI FRIENDLINESS (25 pts)
# ═══════════════════════════════════════════════════════════════

function Measure-AIFriendliness {
    param([string]$RepoPath, [string[]]$AllFiles, [string[]]$SourceFiles, [string[]]$TargetAgents)

    $score = 0
    $details = @{}

    # All known agent config mappings
    $allAgentConfigs = [ordered]@{
        'copilot'    = @('.github/copilot-instructions.md', '.github/copilot-instructions.yaml', 'AGENTS.md', '.github/AGENTS.md')
        'cursor'     = @('.cursorrules', '.cursor/rules')
        'claude'     = @('CLAUDE.md')
        'coderabbit' = @('.coderabbit.yaml', '.coderabbit.yml')
        'aider'      = @('.aider.conf.yml', '.aiderignore')
        'windsurf'   = @('.windsurfrules')
    }

    # Filter to target agents (or all if none specified)
    $agentsToCheck = if ($TargetAgents -and $TargetAgents.Count -gt 0) {
        $TargetAgents | ForEach-Object { $_.ToLower() }
    } else {
        $allAgentConfigs.Keys
    }

    # Agent config files (8pts) — scored per target agent
    $configured = @(); $missing = @()
    foreach ($agent in $agentsToCheck) {
        if (-not $allAgentConfigs.Contains($agent)) {
            $details["Unknown_$agent"] = "⚠️ Unknown agent '$agent' — skipped"
            continue
        }
        $found = $false
        foreach ($path in $allAgentConfigs[$agent]) {
            if ($AllFiles -contains $path) { $found = $true; break }
        }
        if ($found) { $configured += $agent } else { $missing += $agent }
    }
    $targetCount = ($configured.Count + $missing.Count)
    $configRatio = if ($targetCount -gt 0) { $configured.Count / $targetCount } else { 0 }
    $configScore = [Math]::Min(8, [Math]::Round($configRatio * 8))
    $score += $configScore
    $configuredStr = if ($configured.Count -gt 0) { $configured -join ', ' } else { 'None' }
    $missingStr = if ($missing.Count -gt 0) { " | Missing: $($missing -join ', ')" } else { '' }
    $details['AgentConfigs'] = "✅ $configuredStr ($($configured.Count)/$targetCount)$missingStr ($configScore/8 pts)"

    # Architecture / context docs for AI comprehension (5pts)
    $archSignals = 0
    $archPatterns = @('ARCHITECTURE', 'DESIGN', 'architecture', 'design-doc', 'ADR', 'knowledge', 'copilot-docs', 'agent-docs', 'kb', 'OVERVIEW')
    foreach ($pat in $archPatterns) {
        if (@($AllFiles | Where-Object { $_ -match $pat }).Count -gt 0) { $archSignals++; if ($archSignals -ge 3) { break } }
    }
    $archScore = [Math]::Min(5, $archSignals * 2)
    $score += $archScore
    $details['ArchDocs'] = "$archSignals architecture doc signals ($archScore/5 pts)"

    # Code clarity — type annotations, interfaces, consistent naming (7pts)
    $clarityScore = 0
    $sampledSource = @($SourceFiles | Get-Random -Count ([Math]::Min(30, $SourceFiles.Count)) -ErrorAction SilentlyContinue)
    $typeAnnotated = 0; $wellNamed = 0; $totalSampled = $sampledSource.Count

    foreach ($f in $sampledSource) {
        $content = Get-FileContent -RepoPath $RepoPath -RelPath $f -MaxBytes 20000
        if (-not $content) { continue }

        # Type annotations / interfaces / strong typing signals
        if ($content -match '(interface\s+\w+|type\s+\w+\s*=|:\s*(string|int|bool|number|void)|<\w+>|-> \w+|def \w+\(.*:\s*\w+)') {
            $typeAnnotated++
        }
        # Meaningful names (methods > 3 chars, no single-letter params in signatures)
        $shortParams = [regex]::Matches($content, '\(\s*[a-z]\s*[,\)]')
        if ($shortParams.Count -lt 3) { $wellNamed++ }
    }

    if ($totalSampled -gt 0) {
        $typeRatio = $typeAnnotated / $totalSampled
        $nameRatio = $wellNamed / $totalSampled
        $clarityScore = [Math]::Min(7, [Math]::Round(($typeRatio * 4) + ($nameRatio * 3)))
    }
    $score += $clarityScore
    $details['CodeClarity'] = "Types: $typeAnnotated/$totalSampled, Naming: $wellNamed/$totalSampled ($clarityScore/7 pts)"

    # Structured project layout — conventional dirs (5pts)
    $layoutSignals = 0
    $conventionalDirs = @('src', 'lib', 'test', 'tests', 'docs', 'scripts', 'config', '.github', 'spec')
    foreach ($dir in $conventionalDirs) {
        if (@($AllFiles | Where-Object { $_ -match "^$dir/" }).Count -gt 0) { $layoutSignals++ }
    }
    $layoutScore = [Math]::Min(5, [Math]::Round($layoutSignals * 0.8))
    $score += $layoutScore
    $details['ProjectLayout'] = "$layoutSignals conventional directories ($layoutScore/5 pts)"

    return @{ Score = [Math]::Min(25, $score); Max = 25; Details = $details }
}

# ═══════════════════════════════════════════════════════════════
# CATEGORY 4: TEST COVERAGE (15 pts)
# ═══════════════════════════════════════════════════════════════

function Measure-TestCoverage {
    param([string]$RepoPath, [string[]]$AllFiles, [string[]]$SourceFiles, [string[]]$TestFiles)

    $score = 0
    $details = @{}

    # Source-to-test file pairing (10pts)
    $testNames = @{}
    foreach ($t in $TestFiles) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($t) -replace '(Tests?|Spec|_test|_spec|\.test|\.spec)$', ''
        $testNames[$baseName.ToLower()] = $t
    }

    $paired = 0
    $nonTestSource = @($SourceFiles | Where-Object { $_ -notin $TestFiles })
    $sampled = @($nonTestSource | Get-Random -Count ([Math]::Min(50, $nonTestSource.Count)) -ErrorAction SilentlyContinue)
    foreach ($s in $sampled) {
        $baseName = [IO.Path]::GetFileNameWithoutExtension($s).ToLower()
        if ($testNames.ContainsKey($baseName)) { $paired++ }
    }
    $pairRatio = if ($sampled.Count -gt 0) { $paired / $sampled.Count } else { 0 }
    $pairScore = [Math]::Min(10, [Math]::Round($pairRatio * 10))
    $score += $pairScore
    $details['TestPairing'] = "$paired/$($sampled.Count) source files have matching tests ($pairScore/10 pts)"

    # Test infrastructure exists (5pts)
    $infraSignals = 0
    if ($TestFiles.Count -gt 0) { $infraSignals += 2 }
    if (@($AllFiles | Where-Object { $_ -match '(jest\.config|pytest\.ini|\.nunit|xunit|phpunit|go\.mod|Cargo\.toml|\.rspec)' }).Count -gt 0) { $infraSignals++ }
    if (@($AllFiles | Where-Object { $_ -match '(\.github/workflows|\.azure-pipelines|Jenkinsfile|\.circleci|\.gitlab-ci)' }).Count -gt 0) { $infraSignals += 2 }
    $infraScore = [Math]::Min(5, $infraSignals)
    $score += $infraScore
    $details['TestInfra'] = "CI/test config signals: $infraSignals ($infraScore/5 pts)"

    return @{ Score = $score; Max = 15; Details = $details }
}

# ═══════════════════════════════════════════════════════════════
# CATEGORY 5: RISK SIGNALS (20 pts — start at max, deduct)
# ═══════════════════════════════════════════════════════════════

function Measure-RiskSignals {
    param([string]$RepoPath, [string[]]$AllFiles, [string[]]$SourceFiles)

    $score = 20
    $details = @{}

    $sampled = @($SourceFiles | Sort-Object | Select-Object -First ([Math]::Min(40, $SourceFiles.Count)))
    $secretCount = 0; $emptyCatchCount = 0; $todoCount = 0

    foreach ($f in $sampled) {
        # Skip doc/config files for secret detection (high false-positive rate)
        $isDocFile = $f -match '\.(md|rst|txt|adoc|xml|json|yaml|yml)$'
        $content = Get-FileContent -RepoPath $RepoPath -RelPath $f -MaxBytes 30000
        if (-not $content) { continue }

        # Hardcoded secrets — only in source code, skip test files and doc examples
        if (-not $isDocFile -and $f -notmatch '(test|spec|mock|fake|sample|example)') {
            if ($content -match '(?i)(password|secret|apikey|api_key|connectionstring|private_key|access_key)\s*[=:]\s*["''][^\s"'']{8,}["'']') {
                $secretCount++
            }
        }
        # Empty catch blocks
        $emptyCatches = [regex]::Matches($content, 'catch\s*(\([^)]*\))?\s*\{\s*\}')
        $emptyCatchCount += $emptyCatches.Count

        # TODO/FIXME/HACK density
        $todos = [regex]::Matches($content, '(?i)(TODO|FIXME|HACK|XXX|WORKAROUND)')
        $todoCount += $todos.Count
    }

    $secretDeduct = [Math]::Min(8, $secretCount * 4)
    $score -= $secretDeduct
    $details['HardcodedSecrets'] = "$secretCount files with potential secrets (-$secretDeduct pts)"

    $catchDeduct = [Math]::Min(6, $emptyCatchCount * 2)
    $score -= $catchDeduct
    $details['EmptyCatches'] = "$emptyCatchCount empty catch blocks (-$catchDeduct pts)"

    $todoDeduct = [Math]::Min(6, [Math]::Round($todoCount / 5))
    $score -= $todoDeduct
    $details['TodoDensity'] = "$todoCount TODO/FIXME/HACK markers (-$todoDeduct pts)"

    $score = [Math]::Max(0, $score)
    return @{ Score = $score; Max = 20; Details = $details }
}

# ═══════════════════════════════════════════════════════════════
# CATEGORY 6: KNOWLEDGE LAYER COMPLETENESS (15 pts)
# ═══════════════════════════════════════════════════════════════

function Measure-KnowledgeLayer {
    <#
    .SYNOPSIS
        Measures the completeness of the repo's knowledge layer — instructions, skills, workflow docs, doc coverage.
    #>
    param([string]$RepoPath, [string[]]$AllFiles, [string[]]$SourceFiles, [string[]]$DocFiles)

    $score = 0
    $details = @{}

    # copilot-instructions.md exists & substantial (3pts)
    $ci = $AllFiles | Where-Object { $_ -match 'copilot-instructions\.(md|yaml)$' } | Select-Object -First 1
    if ($ci) {
        $content = Get-FileContent -RepoPath $RepoPath -RelPath $ci
        if ($content -and $content.Length -gt 500) { $score += 3; $details['CopilotInstructions'] = "✅ $([Math]::Round($content.Length/1KB,1))KB" }
        else { $score += 1; $details['CopilotInstructions'] = "⚠️ Exists but thin" }
    } else { $details['CopilotInstructions'] = "❌ Not found" }

    # Skills directory (2pts)
    $skills = @($AllFiles | Where-Object { $_ -match '\.github/skills/.*\.md$' })
    if ($skills.Count -ge 2) { $score += 2; $details['Skills'] = "✅ $($skills.Count) skill files" }
    elseif ($skills.Count -gt 0) { $score += 1; $details['Skills'] = "⚠️ $($skills.Count) skill file" }
    else { $details['Skills'] = "❌ None" }

    # Workflow / knowledge docs — scaled by repo size (5pts)
    $workflows = @($AllFiles | Where-Object { $_ -match '(workflows?|knowledge|copilot-docs|agent-docs|kb|agentKT)/.*\.md$' })
    $wfCount = $workflows.Count
    # Scale expectation: ~1 doc per 20 source files is excellent
    $expectedDocs = [Math]::Max(5, [Math]::Round($SourceFiles.Count / 20))
    $wfRatio = if ($expectedDocs -gt 0) { [Math]::Min(1.0, $wfCount / $expectedDocs) } else { 0 }
    $wfScore = [Math]::Min(5, [Math]::Round($wfRatio * 5))
    $score += $wfScore
    $details['WorkflowDocs'] = "$wfCount docs (expected ~$expectedDocs for repo size) ($wfScore/5 pts)"

    # Doc coverage ratio — docs per source file (5pts)
    # Measures how well-documented the codebase is overall
    $docRatio = if ($SourceFiles.Count -gt 0) { $DocFiles.Count / $SourceFiles.Count } else { 0 }
    # Thresholds: 0.05 (1 doc per 20 src) = 1pt, 0.10 = 3pts, 0.15+ = 5pts
    $covScore = if ($docRatio -ge 0.15) { 5 }
                elseif ($docRatio -ge 0.10) { 4 }
                elseif ($docRatio -ge 0.07) { 3 }
                elseif ($docRatio -ge 0.05) { 2 }
                elseif ($docRatio -ge 0.02) { 1 }
                else { 0 }
    $score += $covScore
    $pctCov = [Math]::Round($docRatio * 100, 1)
    $details['DocCoverage'] = "$($DocFiles.Count) docs / $($SourceFiles.Count) source ($pctCov%) ($covScore/5 pts)"

    return @{ Score = [Math]::Min(15, $score); Max = 15; Details = $details }
}

# ═══════════════════════════════════════════════════════════════
# BONUS: MONKEY ARMY SIGNALS (0-10 extra)
# ═══════════════════════════════════════════════════════════════

function Measure-MonkeyArmyBonus {
    param([string]$RepoPath, [string[]]$AllFiles)

    $score = 0
    $details = @{}

    # copilot-instructions.md exists & substantial (3pts)
    $ci = $AllFiles | Where-Object { $_ -match 'copilot-instructions\.(md|yaml)$' } | Select-Object -First 1
    if ($ci) {
        $content = Get-FileContent -RepoPath $RepoPath -RelPath $ci
        if ($content -and $content.Length -gt 500) { $score += 3; $details['CopilotInstructions'] = "✅ $([Math]::Round($content.Length/1KB,1))KB" }
        else { $score += 1; $details['CopilotInstructions'] = "⚠️ Exists but thin" }
    } else { $details['CopilotInstructions'] = "❌ Not found" }

    # Skills directory (2pts)
    $skills = @($AllFiles | Where-Object { $_ -match '\.github/skills/.*\.md$' })
    if ($skills.Count -ge 2) { $score += 2; $details['Skills'] = "✅ $($skills.Count) skill files" }
    elseif ($skills.Count -gt 0) { $score += 1; $details['Skills'] = "⚠️ $($skills.Count) skill file" }
    else { $details['Skills'] = "❌ None" }

    # Discovery manifest (2pts)
    $manifest = $AllFiles | Where-Object { $_ -match 'Discovery_Manifest' } | Select-Object -First 1
    if ($manifest) { $score += 2; $details['DiscoveryManifest'] = "✅ Found" }
    else { $details['DiscoveryManifest'] = "❌ Not found" }

    # Workflow docs (3pts)
    $workflows = @($AllFiles | Where-Object { $_ -match '(workflows?|knowledge|copilot-docs|agent-docs|kb)/.*\.md$' })
    if ($workflows.Count -ge 5) { $score += 3; $details['WorkflowDocs'] = "✅ $($workflows.Count) docs" }
    elseif ($workflows.Count -ge 2) { $score += 2; $details['WorkflowDocs'] = "⚠️ $($workflows.Count) docs" }
    elseif ($workflows.Count -gt 0) { $score += 1; $details['WorkflowDocs'] = "⚠️ $($workflows.Count) doc" }
    else { $details['WorkflowDocs'] = "❌ None" }

    return @{ Score = [Math]::Min(10, $score); Max = 10; Details = $details }
}

# ═══════════════════════════════════════════════════════════════
# MAIN FUNCTION
# ═══════════════════════════════════════════════════════════════

function Get-DocHealthScore {
    <#
    .SYNOPSIS
        Calculates a 0-100 doc health score for a repository.
    .PARAMETER RepoPath
        Path to the repository root.
    .PARAMETER IncludeBonus
        Include Monkey Army bonus signals (adds up to 10 extra points).
    .PARAMETER TargetAgents
        Which AI agents to score for. Options: copilot, cursor, claude, coderabbit, aider, windsurf.
        If omitted, scores for all known agents.
    .PARAMETER Quiet
        Suppress console output, return object only.
    .OUTPUTS
        Hashtable with TotalScore, Grade, Categories, Bonus, Timestamp.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoPath,
        [string[]]$TargetAgents,
        [switch]$IncludeBonus,
        [switch]$Quiet
    )

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    if (-not (Test-Path $RepoPath)) { throw "Repo path not found: $RepoPath" }

    # Gather file lists once
    $allFiles    = @(Get-RepoFiles -RepoPath $RepoPath)
    $sourceFiles = @(Get-SourceFiles -Files $allFiles)
    $docFiles    = @(Get-DocFiles -Files $allFiles)
    $testFiles   = @(Get-TestFiles -Files $allFiles)

    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  📊 DOC HEALTH SCORER" -ForegroundColor Cyan
        Write-Host "  ════════════════════════════════════════" -ForegroundColor DarkGray
        Write-Host "  Repo: $RepoPath" -ForegroundColor DarkGray
        Write-Host "  Files: $($allFiles.Count) total, $($sourceFiles.Count) source, $($docFiles.Count) docs, $($testFiles.Count) tests" -ForegroundColor DarkGray
        Write-Host ""
    }

    # Run all categories
    $codeDocs   = Measure-CodeDocumentation -RepoPath $RepoPath -AllFiles $allFiles -SourceFiles $sourceFiles
    $docQuality = Measure-DocQuality -RepoPath $RepoPath -AllFiles $allFiles -DocFiles $docFiles
    $aiFriendly = Measure-AIFriendliness -RepoPath $RepoPath -AllFiles $allFiles -SourceFiles $sourceFiles -TargetAgents $TargetAgents
    $testCov    = Measure-TestCoverage -RepoPath $RepoPath -AllFiles $allFiles -SourceFiles $sourceFiles -TestFiles $testFiles
    $risk       = Measure-RiskSignals -RepoPath $RepoPath -AllFiles $allFiles -SourceFiles $sourceFiles
    $knowledge  = Measure-KnowledgeLayer -RepoPath $RepoPath -AllFiles $allFiles -SourceFiles $sourceFiles -DocFiles $docFiles

    $totalScore = $codeDocs.Score + $docQuality.Score + $aiFriendly.Score + $testCov.Score + $risk.Score + $knowledge.Score
    $totalMax   = 115

    $bonus = $null
    if ($IncludeBonus) {
        $bonus = Measure-MonkeyArmyBonus -RepoPath $RepoPath -AllFiles $allFiles
        $totalScore += $bonus.Score
        $totalMax += $bonus.Max
    }

    $grade = Get-GradeFromScore -Score $totalScore -Max $totalMax

    $sw.Stop()

    $result = @{
        TotalScore     = $totalScore
        TotalMax       = $totalMax
        Grade          = $grade
        Categories     = [ordered]@{
            CodeDocumentation = $codeDocs
            DocQuality        = $docQuality
            AIFriendliness    = $aiFriendly
            TestCoverage      = $testCov
            RiskSignals       = $risk
            KnowledgeLayer    = $knowledge
        }
        Bonus          = $bonus
        FileStats      = @{
            Total  = $allFiles.Count
            Source = $sourceFiles.Count
            Docs   = $docFiles.Count
            Tests  = $testFiles.Count
        }
        Duration       = $sw.Elapsed.ToString('mm\:ss')
        Timestamp      = (Get-Date).ToString('o')
    }

    if (-not $Quiet) {
        Write-Host "  ┌──────────────────────────┬───────┬─────┐" -ForegroundColor DarkGray
        Write-Host "  │ Category                 │ Score │ Max │" -ForegroundColor DarkGray
        Write-Host "  ├──────────────────────────┼───────┼─────┤" -ForegroundColor DarkGray

        $categories = @(
            @{ Name = '📝 Code Documentation'; S = $codeDocs }
            @{ Name = '✨ Doc Quality';         S = $docQuality }
            @{ Name = '🤖 AI Friendliness';     S = $aiFriendly }
            @{ Name = '🧪 Test Coverage';        S = $testCov }
            @{ Name = '⚠️  Risk Signals';        S = $risk }
            @{ Name = '📚 Knowledge Layer';      S = $knowledge }
        )
        foreach ($cat in $categories) {
            $pct = [Math]::Round(($cat.S.Score / $cat.S.Max) * 100)
            $color = if ($pct -ge 75) { 'Green' } elseif ($pct -ge 50) { 'Yellow' } else { 'Red' }
            $name = $cat.Name.PadRight(24)
            Write-Host "  │ $name │" -NoNewline -ForegroundColor DarkGray
            Write-Host " $($cat.S.Score.ToString().PadLeft(4)) " -NoNewline -ForegroundColor $color
            Write-Host "│ $($cat.S.Max.ToString().PadLeft(3)) │" -ForegroundColor DarkGray
        }

        if ($bonus) {
            $bColor = if ($bonus.Score -ge 7) { 'Green' } elseif ($bonus.Score -ge 4) { 'Yellow' } else { 'Red' }
            Write-Host "  │ 🐒 Monkey Army Bonus    │" -NoNewline -ForegroundColor DarkGray
            Write-Host " $($bonus.Score.ToString().PadLeft(4)) " -NoNewline -ForegroundColor $bColor
            Write-Host "│ $($bonus.Max.ToString().PadLeft(3)) │" -ForegroundColor DarkGray
        }

        Write-Host "  ├──────────────────────────┼───────┼─────┤" -ForegroundColor DarkGray
        $totalColor = if ($totalScore -ge 75) { 'Green' } elseif ($totalScore -ge 50) { 'Yellow' } else { 'Red' }
        Write-Host "  │ TOTAL                    │" -NoNewline -ForegroundColor White
        Write-Host " $($totalScore.ToString().PadLeft(4)) " -NoNewline -ForegroundColor $totalColor
        Write-Host "│ $($totalMax.ToString().PadLeft(3)) │" -ForegroundColor White
        Write-Host "  └──────────────────────────┴───────┴─────┘" -ForegroundColor DarkGray

        $gradeColor = switch ($grade) { 'A' { 'Green' } 'B' { 'Cyan' } 'C' { 'Yellow' } 'D' { 'Red' } default { 'DarkRed' } }
        Write-Host ""
        Write-Host "  Grade: " -NoNewline; Write-Host "$grade" -ForegroundColor $gradeColor -NoNewline
        Write-Host " ($totalScore/$totalMax) — Scored in $($sw.Elapsed.ToString('mm\:ss'))" -ForegroundColor DarkGray
        Write-Host ""
    }

    return $result
}

function Show-ScoreDelta {
    <#
    .SYNOPSIS
        Displays a before/after comparison of two Doc Health Score results.
    #>
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After
    )

    Write-Host ""
    Write-Host "  📊 DOC HEALTH — BEFORE vs AFTER" -ForegroundColor Cyan
    Write-Host "  ════════════════════════════════════════════════════" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  ┌──────────────────────────┬────────┬────────┬────────┐" -ForegroundColor DarkGray
    Write-Host "  │ Category                 │ Before │  After │  Delta │" -ForegroundColor DarkGray
    Write-Host "  ├──────────────────────────┼────────┼────────┼────────┤" -ForegroundColor DarkGray

    $catNames = @(
        @{ Key = 'CodeDocumentation'; Label = '📝 Code Documentation' }
        @{ Key = 'DocQuality';        Label = '✨ Doc Quality' }
        @{ Key = 'AIFriendliness';    Label = '🤖 AI Friendliness' }
        @{ Key = 'TestCoverage';      Label = '🧪 Test Coverage' }
        @{ Key = 'RiskSignals';       Label = '⚠️  Risk Signals' }
        @{ Key = 'KnowledgeLayer';    Label = '📚 Knowledge Layer' }
    )

    foreach ($cat in $catNames) {
        $bCat = if ($Before.Categories -is [hashtable]) { $Before.Categories[$cat.Key] } else { $Before.Categories.($cat.Key) }
        $aCat = if ($After.Categories -is [hashtable]) { $After.Categories[$cat.Key] } else { $After.Categories.($cat.Key) }
        $bScore = if ($bCat) { $bCat.Score } else { 0 }
        $aScore = if ($aCat) { $aCat.Score } else { 0 }
        $delta  = $aScore - $bScore
        $dSign  = if ($delta -gt 0) { "+$delta" } elseif ($delta -eq 0) { " 0" } else { "$delta" }
        $dColor = if ($delta -gt 0) { 'Green' } elseif ($delta -eq 0) { 'DarkGray' } else { 'Red' }
        $label  = $cat.Label.PadRight(24)

        Write-Host "  │ $label │" -NoNewline -ForegroundColor DarkGray
        Write-Host " $($bScore.ToString().PadLeft(5)) " -NoNewline -ForegroundColor DarkGray
        Write-Host "│" -NoNewline -ForegroundColor DarkGray
        Write-Host " $($aScore.ToString().PadLeft(5)) " -NoNewline -ForegroundColor White
        Write-Host "│" -NoNewline -ForegroundColor DarkGray
        Write-Host " $($dSign.PadLeft(5)) " -NoNewline -ForegroundColor $dColor
        Write-Host "│" -ForegroundColor DarkGray
    }

    if ($Before.Bonus -and $After.Bonus) {
        $bB = $Before.Bonus.Score; $aB = $After.Bonus.Score; $dB = $aB - $bB
        $dBSign = if ($dB -gt 0) { "+$dB" } elseif ($dB -eq 0) { " 0" } else { "$dB" }
        $dBColor = if ($dB -gt 0) { 'Green' } elseif ($dB -eq 0) { 'DarkGray' } else { 'Red' }
        Write-Host "  │ 🐒 Monkey Army Bonus    │" -NoNewline -ForegroundColor DarkGray
        Write-Host " $($bB.ToString().PadLeft(5)) " -NoNewline -ForegroundColor DarkGray
        Write-Host "│" -NoNewline -ForegroundColor DarkGray
        Write-Host " $($aB.ToString().PadLeft(5)) " -NoNewline -ForegroundColor White
        Write-Host "│" -NoNewline -ForegroundColor DarkGray
        Write-Host " $($dBSign.PadLeft(5)) " -NoNewline -ForegroundColor $dBColor
        Write-Host "│" -ForegroundColor DarkGray
    }

    Write-Host "  ├──────────────────────────┼────────┼────────┼────────┤" -ForegroundColor DarkGray

    $bTotal = $Before.TotalScore; $aTotal = $After.TotalScore; $dTotal = $aTotal - $bTotal
    $dTotalSign = if ($dTotal -gt 0) { "+$dTotal" } elseif ($dTotal -eq 0) { " 0" } else { "$dTotal" }
    $dTotalColor = if ($dTotal -gt 0) { 'Green' } elseif ($dTotal -eq 0) { 'DarkGray' } else { 'Red' }

    Write-Host "  │ TOTAL                    │" -NoNewline -ForegroundColor White
    Write-Host " $($bTotal.ToString().PadLeft(5)) " -NoNewline -ForegroundColor DarkGray
    Write-Host "│" -NoNewline -ForegroundColor White
    Write-Host " $($aTotal.ToString().PadLeft(5)) " -NoNewline -ForegroundColor White
    Write-Host "│" -NoNewline -ForegroundColor White
    Write-Host " $($dTotalSign.PadLeft(5)) " -NoNewline -ForegroundColor $dTotalColor
    Write-Host "│" -ForegroundColor White
    Write-Host "  └──────────────────────────┴────────┴────────┴────────┘" -ForegroundColor DarkGray

    $bGrade = $Before.Grade; $aGrade = $After.Grade
    Write-Host ""
    Write-Host "  Grade: $bGrade → " -NoNewline -ForegroundColor DarkGray
    $aColor = switch ($aGrade) { 'A' { 'Green' } 'B' { 'Cyan' } 'C' { 'Yellow' } 'D' { 'Red' } default { 'DarkRed' } }
    Write-Host "$aGrade" -ForegroundColor $aColor -NoNewline
    Write-Host "  ($bTotal → $aTotal, delta: $dTotalSign)" -ForegroundColor DarkGray
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════
# EXPORTS
# ═══════════════════════════════════════════════════════════════

Export-ModuleMember -Function @(
    'Get-DocHealthScore'
    'Show-ScoreDelta'
)
