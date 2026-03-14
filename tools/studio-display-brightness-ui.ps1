Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:OS -ne "Windows_NT") {
    throw "This UI tool only works on Windows."
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if (Get-Variable -Name EmbeddedBackendScript -Scope Script -ErrorAction SilentlyContinue) {
    $script:EmbeddedBackendScript = (Get-Variable -Name EmbeddedBackendScript -Scope Script).Value
}
elseif (Get-Variable -Name EmbeddedBackendScript -Scope Global -ErrorAction SilentlyContinue) {
    $script:EmbeddedBackendScript = (Get-Variable -Name EmbeddedBackendScript -Scope Global).Value
}
else {
    $script:EmbeddedBackendScript = $null
}

function Resolve-BackendScript {
    if (-not [string]::IsNullOrWhiteSpace($script:EmbeddedBackendScript)) {
        return "__EMBEDDED__"
    }

    $baseDirs = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $baseDirs.Add($PSScriptRoot)
    }

    if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $commandDir = Split-Path -Parent $PSCommandPath
        if (-not [string]::IsNullOrWhiteSpace($commandDir)) {
            $baseDirs.Add($commandDir)
        }
    }

    if ($MyInvocation -and $MyInvocation.MyCommand -and -not [string]::IsNullOrWhiteSpace($MyInvocation.MyCommand.Path)) {
        $invocationDir = Split-Path -Parent $MyInvocation.MyCommand.Path
        if (-not [string]::IsNullOrWhiteSpace($invocationDir)) {
            $baseDirs.Add($invocationDir)
        }
    }

    $appBaseDir = [System.AppContext]::BaseDirectory
    if (-not [string]::IsNullOrWhiteSpace($appBaseDir)) {
        $baseDirs.Add($appBaseDir)
    }

    $currentDir = (Get-Location).Path
    if (-not [string]::IsNullOrWhiteSpace($currentDir)) {
        $baseDirs.Add($currentDir)
    }

    $seen = @{}
    $uniqueDirs = @()
    foreach ($dir in $baseDirs) {
        $normalized = $dir.TrimEnd([char[]]"\\/")
        if ([string]::IsNullOrWhiteSpace($normalized)) {
            continue
        }

        if ($normalized -match '^[A-Za-z]:$') {
            $normalized = "$normalized\\"
        }

        if (-not $seen.ContainsKey($normalized)) {
            $seen[$normalized] = $true
            $uniqueDirs += $normalized
        }
    }

    $candidates = @()
    foreach ($baseDir in $uniqueDirs) {
        $candidates += (Join-Path $baseDir "studio-display-brightness.ps1")
        $candidates += (Join-Path $baseDir "tools/studio-display-brightness.ps1")

        $parentDir = Split-Path -Parent $baseDir
        if (-not [string]::IsNullOrWhiteSpace($parentDir)) {
            $candidates += (Join-Path $parentDir "tools/studio-display-brightness.ps1")
        }
    }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    $searched = ($uniqueDirs -join ", ")
    throw "Could not locate studio-display-brightness.ps1 backend script. Searched base directories: $searched"
}

$script:BackendScript = Resolve-BackendScript
$script:Displays = @()
$script:Loading = $false
$script:EmbeddedBackendTempFile = $null

if ($script:BackendScript -eq "__EMBEDDED__") {
    $script:EmbeddedBackendTempFile = Join-Path ([IO.Path]::GetTempPath()) ("studio-display-brightness-backend-{0}.ps1" -f [Guid]::NewGuid().ToString("N"))
    Set-Content -LiteralPath $script:EmbeddedBackendTempFile -Value $script:EmbeddedBackendScript -Encoding UTF8
    $script:BackendScript = $script:EmbeddedBackendTempFile
}

function Invoke-Backend {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [int]$Value,
        [int]$Index,
        [string]$Serial
    )

    $invokeParams = @{ Command = $Command }
    if ($PSBoundParameters.ContainsKey("Value")) {
        $invokeParams["Value"] = $Value
    }

    if ($PSBoundParameters.ContainsKey("Index")) {
        $invokeParams["Index"] = $Index
    }

    if ($PSBoundParameters.ContainsKey("Serial") -and -not [string]::IsNullOrWhiteSpace($Serial)) {
        $invokeParams["Serial"] = $Serial
    }

    try {
        $output = & $script:BackendScript @invokeParams 2>&1
        return @($output | ForEach-Object { $_.ToString() })
    }
    catch {
        throw $_.Exception.Message
    }
}

function Parse-DisplayLine {
    param([string]$Line)

    $pattern = '^#(?<index>\d+)\s+serial=(?<serial>.*?)\s+pid=(?<pid>0x[0-9A-Fa-f]+)\s+mi=(?<mi>\S+)\s+brightness=(?<brightness>(?:\d+%|unknown))$'
    if ($Line -notmatch $pattern) {
        return $null
    }

    $brightnessPercent = $null
    if ($Matches["brightness"] -match '^(?<value>\d+)%$') {
        $brightnessPercent = [int]$Matches["value"]
    }

    return [pscustomobject]@{
        Index = [int]$Matches["index"]
        Serial = $Matches["serial"]
        Pid = $Matches["pid"]
        Mi = $Matches["mi"]
        Brightness = $brightnessPercent
    }
}

function Get-Displays {
    $lines = Invoke-Backend -Command "list"
    $parsed = @()

    foreach ($line in $lines) {
        $entry = Parse-DisplayLine -Line $line
        if ($null -ne $entry) {
            $parsed += $entry
        }
    }

    if ($parsed.Count -eq 0) {
        $raw = ($lines -join [Environment]::NewLine)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            throw "No displays found."
        }

        throw $raw
    }

    return $parsed
}

function Get-BrightnessForIndex {
    param([int]$Index)

    $lines = Invoke-Backend -Command "get" -Index $Index
    foreach ($line in $lines) {
        if ($line -match 'brightness=(?<value>\d+)%') {
            return [int]$Matches["value"]
        }
    }

    throw "Could not parse brightness from backend output."
}

function Set-BrightnessForIndex {
    param(
        [int]$Index,
        [int]$Value
    )

    $null = Invoke-Backend -Command "set" -Value $Value -Index $Index
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Studio Display Brightness"
$form.Size = New-Object System.Drawing.Size(470, 250)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false

$displayLabel = New-Object System.Windows.Forms.Label
$displayLabel.Location = New-Object System.Drawing.Point(18, 18)
$displayLabel.Size = New-Object System.Drawing.Size(60, 20)
$displayLabel.Text = "Display"
$form.Controls.Add($displayLabel)

$displayCombo = New-Object System.Windows.Forms.ComboBox
$displayCombo.Location = New-Object System.Drawing.Point(80, 15)
$displayCombo.Size = New-Object System.Drawing.Size(360, 24)
$displayCombo.DropDownStyle = "DropDownList"
$form.Controls.Add($displayCombo)

$brightnessLabel = New-Object System.Windows.Forms.Label
$brightnessLabel.Location = New-Object System.Drawing.Point(18, 62)
$brightnessLabel.Size = New-Object System.Drawing.Size(90, 20)
$brightnessLabel.Text = "Brightness"
$form.Controls.Add($brightnessLabel)

$brightnessSlider = New-Object System.Windows.Forms.TrackBar
$brightnessSlider.Location = New-Object System.Drawing.Point(110, 50)
$brightnessSlider.Size = New-Object System.Drawing.Size(260, 45)
$brightnessSlider.Minimum = 0
$brightnessSlider.Maximum = 100
$brightnessSlider.TickFrequency = 10
$brightnessSlider.SmallChange = 1
$brightnessSlider.LargeChange = 5
$form.Controls.Add($brightnessSlider)

$valueLabel = New-Object System.Windows.Forms.Label
$valueLabel.Location = New-Object System.Drawing.Point(385, 62)
$valueLabel.Size = New-Object System.Drawing.Size(55, 20)
$valueLabel.TextAlign = "MiddleRight"
$valueLabel.Text = "0%"
$form.Controls.Add($valueLabel)

$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Location = New-Object System.Drawing.Point(20, 120)
$refreshButton.Size = New-Object System.Drawing.Size(95, 30)
$refreshButton.Text = "Refresh"
$form.Controls.Add($refreshButton)

$minusButton = New-Object System.Windows.Forms.Button
$minusButton.Location = New-Object System.Drawing.Point(130, 120)
$minusButton.Size = New-Object System.Drawing.Size(45, 30)
$minusButton.Text = "-10"
$form.Controls.Add($minusButton)

$plusButton = New-Object System.Windows.Forms.Button
$plusButton.Location = New-Object System.Drawing.Point(185, 120)
$plusButton.Size = New-Object System.Drawing.Size(45, 30)
$plusButton.Text = "+10"
$form.Controls.Add($plusButton)

$applyButton = New-Object System.Windows.Forms.Button
$applyButton.Location = New-Object System.Drawing.Point(345, 120)
$applyButton.Size = New-Object System.Drawing.Size(95, 30)
$applyButton.Text = "Apply"
$form.Controls.Add($applyButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Location = New-Object System.Drawing.Point(20, 170)
$statusLabel.Size = New-Object System.Drawing.Size(420, 30)
$statusLabel.Text = "Ready"
$statusLabel.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($statusLabel)

function Get-SelectedDisplay {
    if ($displayCombo.SelectedIndex -lt 0 -or $displayCombo.SelectedIndex -ge $script:Displays.Count) {
        return $null
    }

    return $script:Displays[$displayCombo.SelectedIndex]
}

function Set-Status {
    param(
        [string]$Message,
        [bool]$IsError = $false
    )

    $statusLabel.Text = $Message
    $statusLabel.ForeColor = if ($IsError) { [System.Drawing.Color]::Firebrick } else { [System.Drawing.Color]::DimGray }
}

function Refresh-CurrentBrightness {
    $selected = Get-SelectedDisplay
    if ($null -eq $selected) {
        return
    }

    try {
        $brightness = Get-BrightnessForIndex -Index $selected.Index
        $brightnessSlider.Value = [Math]::Max(0, [Math]::Min(100, $brightness))
        $valueLabel.Text = "$brightness%"
    }
    catch {
        Set-Status -Message $_.Exception.Message -IsError $true
    }
}

function Reload-Displays {
    $previousIndex = $null
    $current = Get-SelectedDisplay
    if ($null -ne $current) {
        $previousIndex = $current.Index
    }

    $script:Loading = $true
    try {
        $script:Displays = @(Get-Displays)
        $displayCombo.Items.Clear()

        foreach ($display in $script:Displays) {
            $serialText = if ([string]::IsNullOrWhiteSpace($display.Serial) -or $display.Serial -eq "unknown") {
                "display-{0}" -f $display.Index
            }
            else {
                $display.Serial
            }

            $itemText = "#{0} {1} pid={2} mi={3}" -f $display.Index, $serialText, $display.Pid, $display.Mi
            [void]$displayCombo.Items.Add($itemText)
        }

        if ($script:Displays.Count -eq 0) {
            throw "No compatible displays found."
        }

        $selectedComboIndex = 0
        if ($null -ne $previousIndex) {
            for ($i = 0; $i -lt $script:Displays.Count; $i++) {
                if ($script:Displays[$i].Index -eq $previousIndex) {
                    $selectedComboIndex = $i
                    break
                }
            }
        }

        $displayCombo.SelectedIndex = $selectedComboIndex
        Set-Status -Message ("Detected {0} display(s)" -f $script:Displays.Count)
    }
    catch {
        $displayCombo.Items.Clear()
        $script:Displays = @()
        $valueLabel.Text = "0%"
        Set-Status -Message $_.Exception.Message -IsError $true
    }
    finally {
        $script:Loading = $false
    }

    Refresh-CurrentBrightness
}

$brightnessSlider.Add_Scroll({
    $valueLabel.Text = "{0}%" -f $brightnessSlider.Value
})

$displayCombo.Add_SelectedIndexChanged({
    if ($script:Loading) {
        return
    }

    Refresh-CurrentBrightness
})

$refreshButton.Add_Click({
    Reload-Displays
})

$minusButton.Add_Click({
    $brightnessSlider.Value = [Math]::Max($brightnessSlider.Minimum, $brightnessSlider.Value - 10)
    $valueLabel.Text = "{0}%" -f $brightnessSlider.Value
})

$plusButton.Add_Click({
    $brightnessSlider.Value = [Math]::Min($brightnessSlider.Maximum, $brightnessSlider.Value + 10)
    $valueLabel.Text = "{0}%" -f $brightnessSlider.Value
})

$applyButton.Add_Click({
    $selected = Get-SelectedDisplay
    if ($null -eq $selected) {
        Set-Status -Message "Select a display first." -IsError $true
        return
    }

    try {
        Set-BrightnessForIndex -Index $selected.Index -Value $brightnessSlider.Value
        Refresh-CurrentBrightness
        Set-Status -Message ("Applied brightness {0}%" -f $brightnessSlider.Value)
    }
    catch {
        Set-Status -Message $_.Exception.Message -IsError $true
    }
})

$form.Add_Shown({
    Reload-Displays
})

$form.Add_FormClosed({
    if ($script:EmbeddedBackendTempFile -and (Test-Path -LiteralPath $script:EmbeddedBackendTempFile)) {
        Remove-Item -LiteralPath $script:EmbeddedBackendTempFile -Force -ErrorAction SilentlyContinue
    }
})

[void]$form.ShowDialog()
