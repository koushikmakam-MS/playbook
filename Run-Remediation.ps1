<#
.SYNOPSIS
    Run-Remediation.ps1 — Targeted remediation runner for completeness gate gaps.
.DESCRIPTION
    Runs the completeness gate against a repo, then feeds each remediation
    item to Copilot as a targeted fix prompt. Designed for surgical doc fixes
    without running the full monkey army.

.PARAMETER RepoPath
    Path to the repository.
.PARAMETER Model
    Copilot model to use. Default: auto-detect.
.PARAMETER MaxItems
    Max remediation items to process. Default: 0 (all).
.PARAMETER DryRun
    Show what would be done without executing.
.PARAMETER Commit
    Auto-commit changes after remediation.
.PARAMETER Timeout
    Per-item timeout in seconds. Default: 180.

.EXAMPLE
    .\Run-Remediation.ps1 -RepoPath "C:\Repo\MyRepo" -Commit
.EXAMPLE
    .\Run-Remediation.ps1 -RepoPath "C:\Repo\MyRepo" -DryRun
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [string]$Model,
    [int]$MaxItems = 0,
    [switch]$DryRun,
    [switch]$Commit,
    [int]$Timeout = 180,
    [int]$MaxRetries = 2,
    [int]$BaseDelay = 15
)

$ErrorActionPreference = "Stop"

# ── Import modules ──
Import-Module (Join-Path $PSScriptRoot "shared\MonkeyCommon.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "shared\CompletenessGate.psm1") -Force

Write-MonkeyBanner -Name "Remediation Runner" -Emoji "🔧" -Version "1.0" -Tagline "Targeted completeness fixes"

# ══════════════════════════════════════════════════════════════════
#  PHASE 1: PRE-CHECK — Build contracts & identify gaps
# ══════════════════════════════════════════════════════════════════

Write-Phase "PRE-CHECK" "Building domain contracts and scanning for gaps"

$preResult = Invoke-CompletenessGate -RepoPath $RepoPath
$gateResult = $preResult.GateResult
$queue = $preResult.RemediationQueue

if ($gateResult.Pass) {
    Write-Step "All $($gateResult.TotalContracts) contracts satisfied — nothing to remediate! ✅" "OK"
    exit 0
}

Write-Step "Found $($queue.Count) remediation items across $($gateResult.TotalContracts) domains" "INFO"
Write-Step "  ✅ Satisfied: $($gateResult.Satisfied)" "OK"
Write-Step "  ⚠️  Partial:  $($gateResult.Partial)" "WARN"
Write-Step "  ❌ Missing:   $($gateResult.Missing)" "ERROR"

if ($MaxItems -gt 0 -and $queue.Count -gt $MaxItems) {
    $queue = @($queue | Select-Object -First $MaxItems)
    Write-Step "Capped to $MaxItems items" "INFO"
}

if ($DryRun) {
    Write-Phase "DRY RUN" "Would process $($queue.Count) items:"
    foreach ($item in $queue) {
        $detail = if ($item.SectionName) { "(§$($item.SectionNum) $($item.SectionName))" } else { "" }
        Write-Step "[$($item.Type)] $($item.Domain) → $($item.TargetFile) $detail" "INFO"
    }
    Write-Host ""
    Write-Step "Dry run complete — no changes made." "OK"
    exit 0
}

# ══════════════════════════════════════════════════════════════════
#  PHASE 2: MODEL SELECTION
# ══════════════════════════════════════════════════════════════════

Write-Phase "MODEL" "Selecting Copilot model"

$selectedModel = $Model
if (-not $selectedModel) {
    $selectedModel = Select-MonkeyModel -WorkingDirectory $RepoPath -NonInteractive
    if (-not $selectedModel) { $selectedModel = 'claude-sonnet-4' }
}
Write-Step "Using model: $selectedModel" "OK"

# ══════════════════════════════════════════════════════════════════
#  PHASE 3: REMEDIATION — Process each item
# ══════════════════════════════════════════════════════════════════

Write-Phase "REMEDIATION" "Processing $($queue.Count) items"

$startTime = Get-Date
$succeeded = 0
$failed = 0
$skipped = 0

# Group by domain for better context reuse
$grouped = $queue | Group-Object Domain

foreach ($group in $grouped) {
    $domainName = $group.Name
    $items = $group.Group
    Write-Host ""
    Write-Step "Domain: $domainName ($($items.Count) items)" "INFO"

    # Batch section additions for the same file into one prompt
    $byFile = $items | Group-Object TargetFile

    foreach ($fileGroup in $byFile) {
        $targetFile = $fileGroup.Name
        $fileItems = $fileGroup.Group

        if ($fileItems[0].Type -eq 'CREATE_DOC') {
            # Single prompt to create entire doc
            $item = $fileItems[0]
            Write-Step "  📄 CREATE: $targetFile" "INFO"

            $prompt = @"
$($item.Prompt)

IMPORTANT: Create the file at the exact path relative to the docs root: $targetFile
Analyze the actual source code in the repository to populate each section with accurate content.
Follow the same format as existing workflow docs in the workflows/ folder.
"@
            try {
                $result = Invoke-CopilotWithRetry -Prompt $prompt `
                    -ModelName $selectedModel -WorkingDirectory $RepoPath `
                    -Retries $MaxRetries -BaseDelay $BaseDelay -Timeout $Timeout

                if ($result -and $result.Success) {
                    Write-Step "    ✅ Created" "OK"
                    $succeeded += $fileItems.Count  # counts all sections as satisfied
                } else {
                    Write-Step "    ❌ Failed" "ERROR"
                    $failed += $fileItems.Count
                }
            } catch {
                Write-Step "    ❌ Error: $($_.Exception.Message)" "ERROR"
                $failed += $fileItems.Count
            }
        }
        elseif ($fileItems[0].Type -eq 'ADD_SECTION' -or $fileItems[0].Type -eq 'ADD_MERMAID') {
            # Batch all missing sections for this file into one prompt
            $sectionList = ($fileItems | ForEach-Object { "- ## $($_.SectionNum). $($_.SectionName)" }) -join "`n"
            Write-Step "  📝 ADD $($fileItems.Count) sections to: $targetFile" "INFO"

            $prompt = @"
In the file '$targetFile', add these missing sections:

$sectionList

For each section:
1. Place it in numerical order relative to existing sections
2. Follow the same depth and format as existing sections in the document
3. Base all content on actual source code analysis — do not fabricate
4. Include relevant code file paths, class names, and config keys from the codebase
5. Each section should be substantive (not just a placeholder)

Domain context: $domainName
"@
            try {
                $result = Invoke-CopilotWithRetry -Prompt $prompt `
                    -ModelName $selectedModel -WorkingDirectory $RepoPath `
                    -Retries $MaxRetries -BaseDelay $BaseDelay -Timeout $Timeout

                if ($result -and $result.Success) {
                    Write-Step "    ✅ Added $($fileItems.Count) sections" "OK"
                    $succeeded += $fileItems.Count
                } else {
                    Write-Step "    ❌ Failed" "ERROR"
                    $failed += $fileItems.Count
                }
            } catch {
                Write-Step "    ❌ Error: $($_.Exception.Message)" "ERROR"
                $failed += $fileItems.Count
            }
        }
        elseif ($fileItems[0].Type -eq 'FIX_REF') {
            foreach ($item in $fileItems) {
                Write-Step "  🔗 FIX REF: $($item.DeadRef) in $targetFile" "INFO"
                try {
                    $result = Invoke-CopilotWithRetry -Prompt $item.Prompt `
                        -ModelName $selectedModel -WorkingDirectory $RepoPath `
                        -Retries $MaxRetries -BaseDelay $BaseDelay -Timeout $Timeout
                    if ($result -and $result.Success) {
                        Write-Step "    ✅ Fixed" "OK"
                        $succeeded++
                    } else {
                        Write-Step "    ❌ Failed" "ERROR"
                        $failed++
                    }
                } catch {
                    Write-Step "    ❌ Error: $($_.Exception.Message)" "ERROR"
                    $failed++
                }
            }
        }
    }
}

$elapsed = (Get-Date) - $startTime

# ══════════════════════════════════════════════════════════════════
#  PHASE 4: POST-CHECK — Re-validate completeness
# ══════════════════════════════════════════════════════════════════

Write-Phase "POST-CHECK" "Re-validating completeness contracts"

$postResult = Invoke-CompletenessGate -RepoPath $RepoPath
$postGate = $postResult.GateResult

# ══════════════════════════════════════════════════════════════════
#  PHASE 5: COMMIT (optional)
# ══════════════════════════════════════════════════════════════════

$filesChanged = 0
if ($Commit) {
    Write-Phase "COMMIT" "Staging and committing remediation changes"
    Push-Location $RepoPath
    $gitStatus = & git --no-pager status --porcelain 2>&1
    $docChanges = @($gitStatus | Where-Object { $_ -match 'docs/' })
    $filesChanged = $docChanges.Count

    if ($filesChanged -gt 0) {
        & git add "docs/" 2>&1 | Out-Null
        $commitMsg = "docs: completeness gate remediation ($succeeded/$($queue.Count) items fixed)"
        & git commit -m "$commitMsg`n`nCo-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>" 2>&1 | Out-Null
        Write-Step "Committed $filesChanged file(s)" "OK"
    } else {
        Write-Step "No doc changes to commit" "SKIP"
    }
    Pop-Location
}

# ══════════════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "  ╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "  ║          🔧 REMEDIATION SUMMARY                         ║" -ForegroundColor Cyan
Write-Host "  ╚══════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

$stats = @{
    "Items Processed"    = $queue.Count
    "Succeeded"          = $succeeded
    "Failed"             = $failed
    "Duration"           = $elapsed.ToString('hh\:mm\:ss')
    "Model"              = $selectedModel
    "Pre-gate"           = "$($gateResult.Satisfied)/$($gateResult.TotalContracts) satisfied"
    "Post-gate"          = "$($postGate.Satisfied)/$($postGate.TotalContracts) satisfied"
    "Delta"              = "+$($postGate.Satisfied - $gateResult.Satisfied) contracts"
    "Files Changed"      = $filesChanged
    "Gate Verdict"       = $postGate.Verdict
}

Write-MonkeySummary -Stats $stats -Emoji "🔧"

if ($postGate.Pass) {
    Write-Host "  🎉 All contracts satisfied! Completeness gate PASSED!" -ForegroundColor Green
} else {
    Write-Host "  ⚠️  $($postGate.TotalContracts - $postGate.Satisfied) contract(s) still incomplete" -ForegroundColor Yellow
    Write-Host "  Run again or use full monkey army to address remaining gaps" -ForegroundColor Yellow
}

Write-Host ""
