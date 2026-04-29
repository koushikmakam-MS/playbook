<#
.SYNOPSIS
    DocLayers.psm1 — Layer classification and tagging for DAG-complete documentation
.DESCRIPTION
    Classifies docs into L0/L1/L2/L3 layers by folder and filename conventions.
    Reads and writes <!-- layer: Lx --> frontmatter tags.
    Generates Navigation Guide tables for Discovery_Manifest.md.
    Used by Build-DocRegistry, Run-Retrofit, and CompletenessGate.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ═══════════════════════════════════════════════════════════════
# CONSTANTS
# ═══════════════════════════════════════════════════════════════

# Layer definitions: L0 (anchor), L1 (architecture), L2 (reference), L3 (workflows/flows)
$script:LayerDefinitions = @{
    L0 = @{
        Label       = 'L0-foundations'
        Purpose     = 'What is this repo?'
        Description = 'Anchor docs — repo map, registry, entry point for all navigation'
    }
    L1 = @{
        Label       = 'L1-conceptual'
        Purpose     = 'Why is it built this way?'
        Description = 'Architecture, glossary, memory, design rationale'
    }
    L2 = @{
        Label       = 'L2-reference'
        Purpose     = 'How does it work internally?'
        Description = 'Error catalogs, telemetry, ADRs, skills, exemplars'
    }
    L3 = @{
        Label       = 'L3-flows'
        Purpose     = 'How do I do X?'
        Description = 'Workflow docs, end-to-end procedures, step-by-step guides'
    }
}

# Classification rules: pattern → layer (evaluated in order, first match wins)
$script:ClassificationRules = @(
    # L0 — Anchors
    @{ Pattern = 'Discovery_Manifest'; Layer = 'L0'; Role = 'anchor' }
    @{ Pattern = 'doc_registry';       Layer = 'L0'; Role = 'index' }
    @{ Pattern = 'copilot-instructions'; Layer = 'L0'; Role = 'agent-config' }

    # L1 — Architecture & Conceptual
    @{ Pattern = 'Architecture_Memory'; Layer = 'L1'; Role = 'architecture' }
    @{ Pattern = 'copilot-memory';      Layer = 'L1'; Role = 'architecture' }
    @{ Pattern = 'Glossary';            Layer = 'L1'; Role = 'glossary' }
    @{ Pattern = 'ARCHITECTURE';        Layer = 'L1'; Role = 'architecture' }

    # L2 — Reference & Deep Internals
    @{ Pattern = 'ErrorCode_Reference'; Layer = 'L2'; Role = 'error-catalog' }
    @{ Pattern = 'Telemetry';           Layer = 'L2'; Role = 'telemetry' }
    @{ Pattern = 'Code_Exemplars';      Layer = 'L2'; Role = 'exemplars' }
    @{ Pattern = 'SKILL\.md$';          Layer = 'L2'; Role = 'skill' }

    # L3 — Flows (matched by folder, see Get-DocLayer logic)

    # L2 — ADRs (matched by folder, see Get-DocLayer logic)
)

# Folder-based overrides (folder name → layer)
$script:FolderLayerMap = @{
    'workflows'  = 'L3'
    'adr'        = 'L2'
    'skills'     = 'L2'
    'exemplars'  = 'L2'
    'reference'  = 'L2'
    'testing'    = 'L2'
}

# ═══════════════════════════════════════════════════════════════
# PRIVATE HELPERS
# ═══════════════════════════════════════════════════════════════

function Get-RelativePath {
    param(
        [string]$FullPath,
        [string]$BasePath
    )
    # Normalize to forward slashes for comparison
    $normFull = $FullPath.Replace('\', '/')
    $normBase = $BasePath.Replace('\', '/').TrimEnd('/')

    # Try Resolve-Path first (works for real paths)
    $resolvedFull = (Resolve-Path $FullPath -ErrorAction SilentlyContinue)
    $resolvedBase = (Resolve-Path $BasePath -ErrorAction SilentlyContinue)
    if ($resolvedFull -and $resolvedBase) {
        $rF = $resolvedFull.Path.Replace('\', '/')
        $rB = $resolvedBase.Path.Replace('\', '/').TrimEnd('/')
        if ($rF.StartsWith($rB + '/')) {
            return $rF.Substring($rB.Length + 1)
        }
    }

    # Fallback: string-based comparison (for paths that don't exist on disk)
    if ($normFull.StartsWith($normBase + '/')) {
        return $normFull.Substring($normBase.Length + 1)
    }
    return $normFull
}

# ═══════════════════════════════════════════════════════════════
# PUBLIC FUNCTIONS — EXPORTED
# ═══════════════════════════════════════════════════════════════

function Get-DocLayer {
    <#
    .SYNOPSIS
        Classify a doc file into L0/L1/L2/L3 based on filename and folder.
    .PARAMETER FilePath
        Full or relative path to the markdown file.
    .PARAMETER RepoPath
        Repository root (for relative path computation).
    .OUTPUTS
        PSCustomObject with: Layer, Role, FilePath, RelPath
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [string]$RepoPath = '.'
    )

    $fileName = [System.IO.Path]::GetFileName($FilePath)
    $relPath = Get-RelativePath -FullPath $FilePath -BasePath $RepoPath

    # 1. Check filename-based rules first
    foreach ($rule in $script:ClassificationRules) {
        if ($fileName -match $rule.Pattern -or $relPath -match $rule.Pattern) {
            return [PSCustomObject]@{
                Layer   = $rule.Layer
                Role    = $rule.Role
                FilePath = $FilePath
                RelPath  = $relPath
            }
        }
    }

    # 2. Check folder-based rules
    $pathParts = $relPath.Replace('\', '/').Split('/')
    foreach ($part in $pathParts) {
        $partLower = $part.ToLower()
        if ($script:FolderLayerMap.ContainsKey($partLower)) {
            $layer = $script:FolderLayerMap[$partLower]
            $role = switch ($partLower) {
                'workflows' { 'workflow' }
                'adr'       { 'decision-record' }
                'skills'    { 'skill' }
                'exemplars' { 'exemplar' }
                'reference' { 'reference' }
                'testing'   { 'test-doc' }
                default     { 'doc' }
            }
            return [PSCustomObject]@{
                Layer   = $layer
                Role    = $role
                FilePath = $FilePath
                RelPath  = $relPath
            }
        }
    }

    # 3. Default: L1 (conceptual/general)
    return [PSCustomObject]@{
        Layer   = 'L1'
        Role    = 'general'
        FilePath = $FilePath
        RelPath  = $relPath
    }
}

function Get-DocLayerTag {
    <#
    .SYNOPSIS
        Read the <!-- layer: Lx --> tag from a doc file's frontmatter.
    .PARAMETER FilePath
        Path to the markdown file.
    .OUTPUTS
        PSCustomObject with: Layer, Role, ReadOrder (or $null if no tag found)
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    if (-not (Test-Path $FilePath)) { return $null }

    # Read first 5 lines to find frontmatter tag
    $lines = Get-Content $FilePath -TotalCount 5 -ErrorAction SilentlyContinue
    if (-not $lines) { return $null }

    foreach ($line in $lines) {
        if ($line -match '<!--\s*layer:\s*(L[0-3])\s*(?:\|\s*role:\s*(\S+))?\s*(?:\|\s*read-order:\s*(\d+))?\s*-->') {
            return [PSCustomObject]@{
                Layer     = $Matches[1]
                Role      = if ($Matches[2]) { $Matches[2] } else { $null }
                ReadOrder = if ($Matches[3]) { [int]$Matches[3] } else { $null }
            }
        }
    }
    return $null
}

function Set-DocLayerTag {
    <#
    .SYNOPSIS
        Add or update the <!-- layer: Lx --> tag in a doc file.
    .PARAMETER FilePath
        Path to the markdown file.
    .PARAMETER Layer
        Layer label: L0, L1, L2, or L3.
    .PARAMETER Role
        Optional role description.
    .PARAMETER ReadOrder
        Optional numeric read order within the layer.
    .OUTPUTS
        $true if tag was added/updated, $false if file not found.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        [ValidateSet('L0', 'L1', 'L2', 'L3')]
        [string]$Layer,
        [string]$Role,
        [int]$ReadOrder = -1
    )

    if (-not (Test-Path $FilePath)) { return $false }

    $content = Get-Content $FilePath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { return $false }

    # Build tag
    $tag = "<!-- layer: $Layer"
    if ($Role) { $tag += " | role: $Role" }
    if ($ReadOrder -ge 0) { $tag += " | read-order: $ReadOrder" }
    $tag += " -->"

    # Check if tag already exists
    if ($content -match '<!--\s*layer:\s*L[0-3].*?-->') {
        # Replace existing tag
        $content = $content -replace '<!--\s*layer:\s*L[0-3].*?-->', $tag
    }
    else {
        # Prepend tag before first line
        $content = "$tag`n$content"
    }

    Set-Content $FilePath -Value $content -NoNewline -Encoding UTF8
    return $true
}

function Get-AllDocLayers {
    <#
    .SYNOPSIS
        Classify all markdown docs under a docs root into layers.
    .PARAMETER DocsRoot
        Path to the docs directory (e.g., docs/agentKT).
    .PARAMETER RepoPath
        Repository root for relative path computation.
    .OUTPUTS
        Array of PSCustomObject: Layer, Role, FilePath, RelPath, ExistingTag
    #>
    param(
        [Parameter(Mandatory)]
        [string]$DocsRoot,
        [string]$RepoPath = '.'
    )

    if (-not (Test-Path $DocsRoot)) { return @() }

    $results = @()
    $mdFiles = Get-ChildItem $DocsRoot -Filter '*.md' -Recurse -File -ErrorAction SilentlyContinue

    foreach ($file in $mdFiles) {
        $classification = Get-DocLayer -FilePath $file.FullName -RepoPath $RepoPath
        $existingTag = Get-DocLayerTag -FilePath $file.FullName

        $results += [PSCustomObject]@{
            Layer       = $classification.Layer
            Role        = $classification.Role
            FilePath    = $file.FullName
            RelPath     = $classification.RelPath
            ExistingTag = $existingTag
            Tagged      = ($null -ne $existingTag)
        }
    }

    return $results
}

function Get-LayerSummary {
    <#
    .SYNOPSIS
        Summarize doc counts per layer.
    .PARAMETER DocLayers
        Array from Get-AllDocLayers.
    .OUTPUTS
        Hashtable: L0=N, L1=N, L2=N, L3=N, Total=N, Tagged=N, Untagged=N
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$DocLayers
    )

    $summary = @{
        L0      = @($DocLayers | Where-Object { $_.Layer -eq 'L0' }).Count
        L1      = @($DocLayers | Where-Object { $_.Layer -eq 'L1' }).Count
        L2      = @($DocLayers | Where-Object { $_.Layer -eq 'L2' }).Count
        L3      = @($DocLayers | Where-Object { $_.Layer -eq 'L3' }).Count
        Total   = $DocLayers.Count
        Tagged  = @($DocLayers | Where-Object { $_.Tagged }).Count
        Untagged = @($DocLayers | Where-Object { -not $_.Tagged }).Count
    }
    return $summary
}

function Build-NavigationGuide {
    <#
    .SYNOPSIS
        Generate a Navigation Guide table for Discovery_Manifest.md.
    .DESCRIPTION
        Builds a markdown table mapping common questions to reading chains
        (L0 → L1 → L2 → L3) based on classified docs.
    .PARAMETER DocLayers
        Array from Get-AllDocLayers.
    .PARAMETER RepoPath
        Repository root for relative paths.
    .OUTPUTS
        String containing the markdown Navigation Guide section.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [array]$DocLayers,
        [string]$RepoPath = '.'
    )

    $l0Docs = @($DocLayers | Where-Object { $_.Layer -eq 'L0' })
    $l1Docs = @($DocLayers | Where-Object { $_.Layer -eq 'L1' })
    $l2Docs = @($DocLayers | Where-Object { $_.Layer -eq 'L2' })
    $l3Docs = @($DocLayers | Where-Object { $_.Layer -eq 'L3' })

    $anchor = if ($l0Docs.Count -gt 0) {
        $l0Docs | Where-Object { $_.Role -eq 'anchor' } | Select-Object -First 1
    } else { $null }
    $anchorRef = if ($anchor) { "THIS doc (L0)" } else { "Discovery_Manifest.md (L0)" }

    $lines = @()
    $lines += ''
    $lines += '## Navigation Guide'
    $lines += ''
    $lines += '> **Reading order:** Always start at L0 (this doc), then follow the chain for your question.'
    $lines += '> Layers: L0 (what) → L1 (why/architecture) → L2 (how/reference) → L3 (do/workflows)'
    $lines += ''
    $lines += '| Question | Start Here | Then Read |'
    $lines += '|----------|-----------|-----------|'

    # "What is this repo?" → L0 anchor → L1 architecture
    $archDoc = $l1Docs | Where-Object { $_.Role -eq 'architecture' } | Select-Object -First 1
    if ($archDoc) {
        $relP = $archDoc.RelPath
        $lines += '| "What is this repo?" | ' + $anchorRef + ' | `' + $relP + '` (L1) |'
    }

    # "How does X workflow work?" → L0 → L3 workflows
    foreach ($wf in ($l3Docs | Where-Object { $_.Role -eq 'workflow' } | Select-Object -First 5)) {
        $wfName = [System.IO.Path]::GetFileNameWithoutExtension($wf.RelPath) -replace '^\d+_', '' -replace '_', ' '
        $relP = $wf.RelPath
        $lines += '| "How does ' + $wfName + ' work?" | ' + $anchorRef + ' | `' + $relP + '` (L3) |'
    }

    # "What errors can occur?" → L0 → L2 error catalog
    $errDoc = $l2Docs | Where-Object { $_.Role -eq 'error-catalog' } | Select-Object -First 1
    if ($errDoc) {
        $relP = $errDoc.RelPath
        $lines += '| "What errors can occur?" | ' + $anchorRef + ' | `' + $relP + '` (L2) |'
    }

    # "What terms/acronyms?" → L0 → L1 glossary
    $glossary = $l1Docs | Where-Object { $_.Role -eq 'glossary' } | Select-Object -First 1
    if ($glossary) {
        $relP = $glossary.RelPath
        $lines += '| "What terms/acronyms are used?" | ' + $anchorRef + ' | `' + $relP + '` (L1) |'
    }

    # "How to write code here?" → L0 → L2 skills
    $skillDoc = $l2Docs | Where-Object { $_.Role -eq 'skill' } | Select-Object -First 1
    if ($skillDoc) {
        $relP = $skillDoc.RelPath
        $lines += '| "How to write code here?" | ' + $anchorRef + ' | `' + $relP + '` (L2) |'
    }

    $lines += ''
    return ($lines -join "`n")
}

function Get-LayerDefinitions {
    <#
    .SYNOPSIS
        Returns the layer definitions hashtable for external use.
    #>
    return $script:LayerDefinitions
}

# ─────────────────────────────────────────────
# Export all public functions
# ─────────────────────────────────────────────

Export-ModuleMember -Function @(
    'Get-DocLayer'
    'Get-DocLayerTag'
    'Set-DocLayerTag'
    'Get-AllDocLayers'
    'Get-LayerSummary'
    'Build-NavigationGuide'
    'Get-LayerDefinitions'
)
