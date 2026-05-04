# Generates a 64-row resolution-IV 2^(12-6) design and drives ModelSim through run_sweep.tcl.
#
# Usage:
#   pwsh -File sweep.ps1                  # full sweep (resumes if results.csv exists)
#   pwsh -File sweep.ps1 -RunCycles 2000  # shorter sims per row
#   pwsh -File sweep.ps1 -Reset           # wipes results.csv first
#   pwsh -File sweep.ps1 -SmokeRows 2     # runs only the first N design rows

[CmdletBinding()]
param(
    [int]    $RunCycles  = 5000,
    [switch] $Reset,
    [int]    $SmokeRows  = 0,
    [switch] $DesignOnly,
    [string] $VsimExe    = "vsim"
)

$ErrorActionPreference = "Stop"

# Resolves paths from the script's own location so cwd does not matter.
$ScriptDir  = Split-Path -Parent $PSCommandPath
$SimDir     = Split-Path -Parent $ScriptDir
$DesignFull = Join-Path $ScriptDir "design_full.csv"
$DesignTodo = Join-Path $ScriptDir "design_remaining.csv"
$Results    = Join-Path $ScriptDir "results.csv"

# Brackets each TB default at ~0.5x/2x, clamped to the 10-bit param field.
$Axes = @(
    @{ name = "p1_noise"; low = 350;  high = 1023 },
    @{ name = "p2_noise"; low = 16;   high = 64   },
    @{ name = "p3_noise"; low = 4;    high = 16   },
    @{ name = "p1_mm";    low = 400;  high = 1023 },
    @{ name = "p2_mm";    low = 2;    high = 8    },
    @{ name = "p3_mm";    low = 3;    high = 10   },
    @{ name = "p1_mom";   low = 8;    high = 30   },
    @{ name = "p2_mom";   low = 2;    high = 8    },
    @{ name = "p3_mom";   low = 2;    high = 8    },
    @{ name = "p1_val";   low = 4;    high = 16   },
    @{ name = "p2_val";   low = 8;    high = 32   },
    @{ name = "p3_val";   low = 5;    high = 20   }
)

# Derives axes 6..11 as products of three base axes; defining words of length 4 keep main
# effects clear of 2-way interactions.
$Generators = @(
    @{ axis_index = 6;  source_axes = @(0, 1, 2) },
    @{ axis_index = 7;  source_axes = @(0, 1, 3) },
    @{ axis_index = 8;  source_axes = @(0, 2, 3) },
    @{ axis_index = 9;  source_axes = @(1, 2, 3) },
    @{ axis_index = 10; source_axes = @(0, 1, 4) },
    @{ axis_index = 11; source_axes = @(0, 2, 4) }
)

function Write-Design {
    param([string]$Path)

    $header = @("tag")
    foreach ($axis in $Axes) { $header += $axis.name }
    $header += "run_cycles"
    $rows = @()
    $rows += ($header -join ",")

    for ($row_index = 0; $row_index -lt 64; $row_index++) {
        # Drives the six base axes from bits 0..5 of the row index.
        $sign = New-Object int[] 12
        for ($bit_index = 0; $bit_index -lt 6; $bit_index++) {
            $sign[$bit_index] = if ((($row_index -shr $bit_index) -band 1) -eq 1) { 1 } else { -1 }
        }
        # Folds in the derived axes via their generator product.
        foreach ($generator in $Generators) {
            $product = 1
            foreach ($source in $generator.source_axes) { $product *= $sign[$source] }
            $sign[$generator.axis_index] = $product
        }

        $values = @()
        for ($axis_index = 0; $axis_index -lt 12; $axis_index++) {
            $axis = $Axes[$axis_index]
            if ($sign[$axis_index] -eq 1) { $values += $axis.high } else { $values += $axis.low }
        }

        $tag = "row_{0:D3}" -f $row_index
        $rows += (@($tag) + $values + @($RunCycles)) -join ","
    }

    $rows | Set-Content -Path $Path -Encoding ASCII
}

# Mirrors the TB's summary layout; written once so the TB always appends.
$ResultsHeader = @(
    "tag",
    "p1_noise","p2_noise","p3_noise",
    "p1_mm","p2_mm","p3_mm",
    "p1_mom","p2_mom","p3_mom",
    "p1_val","p2_val","p3_val",
    "total_cycles","total_trades","trade_rate",
    "drift_mse","terminal_drift","mean_abs_drift",
    "max_drawdown","min_exec_tick","max_exec_tick",
    "mean_spread","mean_bid_qty","mean_ask_qty",
    "qty_noise","qty_mm","qty_mom","qty_val",
    "crossed","phantom","fifo_full","conservation","invalid_price"
) -join ","

if ($Reset -and (Test-Path $Results)) {
    Remove-Item $Results
}

Write-Host "[sweep] generating design_full.csv ($RunCycles cycles per row)"
Write-Design -Path $DesignFull

if ($DesignOnly) {
    Write-Host "[sweep] -DesignOnly set; skipping ModelSim run"
    return
}

if (-not (Test-Path $Results)) {
    $ResultsHeader | Set-Content -Path $Results -Encoding ASCII
}

# Drops rows whose tag is already in results.csv (resumability).
$completed = @{}
$existing = Import-Csv $Results
foreach ($row in $existing) {
    if ($row.tag) { $completed[$row.tag] = $true }
}

$design_lines = Get-Content $DesignFull
$header = $design_lines[0]
$data_lines = $design_lines | Select-Object -Skip 1 | Where-Object {
    $tag = ($_ -split ",")[0]
    -not $completed.ContainsKey($tag)
}

if ($SmokeRows -gt 0) {
    $data_lines = $data_lines | Select-Object -First $SmokeRows
}

if ($data_lines.Count -eq 0) {
    Write-Host "[sweep] all 64 rows already in results.csv; nothing to run"
    return
}

@($header) + $data_lines | Set-Content -Path $DesignTodo -Encoding ASCII
Write-Host ("[sweep] {0} rows queued ({1} already complete)" -f `
    $data_lines.Count, $completed.Count)

# Hands control to ModelSim.
Push-Location $SimDir
try {
    & $VsimExe -c -do "do run_sweep.tcl; quit -f"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "vsim exited with code $LASTEXITCODE"
    }
}
finally {
    Pop-Location
}

Write-Host "[sweep] done. results -> $Results"
