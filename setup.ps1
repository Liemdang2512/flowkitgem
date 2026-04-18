# Flow Kit — Windows Setup Script (PowerShell)
# Usage: Right-click → "Run with PowerShell" OR run: powershell -ExecutionPolicy Bypass -File setup.ps1

$ErrorActionPreference = "Stop"

Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Flow Kit — Setup (Windows)"             -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$ERRORS = 0

# ─── Python ──────────────────────────────────────────────────
Write-Host "Checking Python..."
$pyCmd = $null
foreach ($cmd in @("python", "python3")) {
    try {
        $ver = & $cmd --version 2>&1
        if ($ver -match "Python (\d+)\.(\d+)") {
            $major = [int]$Matches[1]; $minor = [int]$Matches[2]
            if ($major -ge 3 -and $minor -ge 10) {
                Write-Host "  OK: $ver" -ForegroundColor Green
                $pyCmd = $cmd; break
            } else {
                Write-Host "  WARNING: $ver found, 3.10+ recommended" -ForegroundColor Yellow
                $pyCmd = $cmd; break
            }
        }
    } catch {}
}
if (-not $pyCmd) {
    Write-Host "  MISSING: Python 3 not found" -ForegroundColor Red
    Write-Host "  Install: https://www.python.org/downloads/"
    Write-Host "  Or via winget: winget install Python.Python.3.12"
    $ERRORS++
}

# ─── Node.js ─────────────────────────────────────────────────
Write-Host "Checking Node.js..."
try {
    $nodeVer = node --version 2>&1
    Write-Host "  OK: Node.js $nodeVer" -ForegroundColor Green
} catch {
    Write-Host "  MISSING: Node.js not found" -ForegroundColor Red
    Write-Host "  Install: https://nodejs.org/"
    Write-Host "  Or via winget: winget install OpenJS.NodeJS"
    $ERRORS++
}

# ─── ffmpeg ──────────────────────────────────────────────────
Write-Host "Checking ffmpeg..."
try {
    $ffVer = ffmpeg -version 2>&1 | Select-Object -First 1
    Write-Host "  OK: $ffVer" -ForegroundColor Green
} catch {
    Write-Host "  MISSING: ffmpeg not found" -ForegroundColor Yellow
    Write-Host "  Install: winget install Gyan.FFmpeg"
    Write-Host "  Or: https://ffmpeg.org/download.html"
    Write-Host "  (needed for video concat/trim)"
    # Not fatal — user can install later
}

# ─── Chrome ──────────────────────────────────────────────────
Write-Host "Checking Chrome..."
$chromePaths = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe",
    "$env:LocalAppData\Google\Chrome\Application\chrome.exe"
)
$chromeFound = $chromePaths | Where-Object { Test-Path $_ }
if ($chromeFound) {
    Write-Host "  OK: Chrome found" -ForegroundColor Green
} else {
    Write-Host "  WARNING: Chrome not detected — needed for extension" -ForegroundColor Yellow
    Write-Host "  Download: https://www.google.com/chrome/"
}

Write-Host ""

# ─── Abort if critical missing ───────────────────────────────
if ($ERRORS -gt 0) {
    Write-Host "Found $ERRORS missing dependency(ies). Install them and re-run." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# ─── Virtual environment ────────────────────────────────────
Write-Host "Setting up Python virtual environment..."
if (-not (Test-Path "$SCRIPT_DIR\venv")) {
    & $pyCmd -m venv "$SCRIPT_DIR\venv"
    Write-Host "  Created: venv\" -ForegroundColor Green
} else {
    Write-Host "  Exists: venv\" -ForegroundColor Green
}

# ─── Activate & install ─────────────────────────────────────
Write-Host "Installing Python dependencies..."
$pip = "$SCRIPT_DIR\venv\Scripts\pip.exe"
& $pip install -q --upgrade pip
& $pip install -q -r "$SCRIPT_DIR\requirements.txt"
Write-Host "  Done" -ForegroundColor Green

# ─── Verify import ──────────────────────────────────────────
Write-Host "Verifying agent can import..."
$python = "$SCRIPT_DIR\venv\Scripts\python.exe"
try {
    & $python -c "from agent.main import app; print('  OK: agent.main imports successfully')"
} catch {
    Write-Host "  FAILED: agent cannot import" -ForegroundColor Red
    exit 1
}

# ─── Install fk:* skills ────────────────────────────────────
Write-Host "Installing fk:* skills..."

$SKILLS_SRC = "$SCRIPT_DIR\skills"

function Install-Skills {
    param($TargetDir, $Label, $ConfigFile)

    if (-not (Test-Path $TargetDir)) {
        Write-Host "  SKIP ${Label}: $TargetDir not found (install the CLI first)" -ForegroundColor Yellow
        return
    }

    $skillsDst = "$TargetDir\skills"
    New-Item -ItemType Directory -Force -Path $skillsDst | Out-Null

    # Write config MD
    $srcMd = "$SCRIPT_DIR\$ConfigFile"
    $dstMd = "$TargetDir\$ConfigFile"
    if (Test-Path $srcMd) {
        if ($ConfigFile -eq "CLAUDE.md") {
            if ((Test-Path $dstMd) -and (Get-Content $dstMd -Raw) -match "Flow Kit") {
                Write-Host "  OK ${Label}: CLAUDE.md already has Flow Kit section" -ForegroundColor Green
            } else {
                Get-Content $srcMd | Add-Content $dstMd
                Write-Host "  OK ${Label}: Flow Kit appended to CLAUDE.md" -ForegroundColor Green
            }
        } else {
            Copy-Item $srcMd $dstMd -Force
            Write-Host "  OK ${Label}: $ConfigFile written" -ForegroundColor Green
        }
    }

    # Install each skill
    $count = 0
    Get-ChildItem "$SKILLS_SRC\fk:*.md" | ForEach-Object {
        $skillName = $_.BaseName
        $skillDir = "$skillsDst\$skillName"
        New-Item -ItemType Directory -Force -Path $skillDir | Out-Null
        $firstLine = (Get-Content $_.FullName -First 1) -replace '^#+\s*', ''
        $header = "---`nname: $skillName`ndescription: $firstLine`n---`n`n"
        $content = Get-Content $_.FullName -Raw
        Set-Content "$skillDir\SKILL.md" ($header + $content) -Encoding UTF8
        $count++
    }
    Write-Host "  OK ${Label}: $count skills installed" -ForegroundColor Green
}

Install-Skills "$env:USERPROFILE\.gemini" "Gemini CLI" "GEMINI.md"
Install-Skills "$env:USERPROFILE\.claude" "Claude Code" "CLAUDE.md"

Write-Host ""
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host "  Setup complete!"                         -ForegroundColor Cyan
Write-Host "=========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  1. Load Chrome extension:"
Write-Host "     chrome://extensions -> Developer mode -> Load unpacked -> extension\"
Write-Host ""
Write-Host "  2. Open Google Flow:"
Write-Host "     https://labs.google/fx/tools/flow (sign in)"
Write-Host ""
Write-Host "  3. Start the agent:"
Write-Host "     venv\Scripts\activate"
Write-Host "     python -m agent.main"
Write-Host ""
Write-Host "  4. Verify:"
Write-Host "     curl http://127.0.0.1:8100/health"
Write-Host ""
Read-Host "Press Enter to exit"
