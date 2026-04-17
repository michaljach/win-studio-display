#_pragma noConsole
#_pragma title "Studio Display Brightness"
#_pragma product "Studio Display Brightness"
#_pragma company "win-studio-display"

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:UiBuildId = "2026-03-17.1"

if ($env:OS -ne "Windows_NT") {
    throw "This UI tool only works on Windows."
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:Displays = @()
$script:Loading = $false
$script:ErrorLogPath = Join-Path ([IO.Path]::GetTempPath()) "studio-display-brightness-ui.log"

function Write-UiLog {
    param([string]$Message)

    try {
        $stamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        Add-Content -LiteralPath $script:ErrorLogPath -Value "[$stamp] $Message"
    }
    catch { }
}

function Invoke-Backend {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Command,
        [int]$Value,
        [int]$Index,
        [string]$Serial
    )

    $scriptArgs = New-Object System.Collections.Generic.List[string]
    $scriptArgs.Add($Command)

    if ($PSBoundParameters.ContainsKey("Value")) {
        $scriptArgs.Add($Value.ToString())
    }

    if ($PSBoundParameters.ContainsKey("Index")) {
        $scriptArgs.Add("-Index")
        $scriptArgs.Add($Index.ToString())
    }

    if ($PSBoundParameters.ContainsKey("Serial") -and -not [string]::IsNullOrWhiteSpace($Serial)) {
        $scriptArgs.Add("-Serial")
        $scriptArgs.Add($Serial)
    }

    try {
        $nativeArgs = $scriptArgs.ToArray()
        $renderedArgs = $scriptArgs | ForEach-Object {
            if ([string]$_ -match "\s") {
                '"{0}"' -f $_
            }
            else {
                $_
            }
        }
        $backendPathForLog = Join-Path $PSScriptRoot "studio-display-brightness.ps1"
        $debugCommand = "{0} {1}" -f $backendPathForLog, ($renderedArgs -join " ")

        Write-UiLog -Message ("UI build={0} invoking: {1}" -f $script:UiBuildId, $debugCommand)
        $output = & $PSScriptRoot/studio-display-brightness.ps1 @nativeArgs 2>&1
        $textOutput = @($output | ForEach-Object { $_.ToString() })
        if ($textOutput.Count -gt 0) {
            Write-UiLog -Message ("UI build={0} output: {1}" -f $script:UiBuildId, ($textOutput -join " | "))
        }
        return $textOutput
    }
    catch {
        $renderedArgs = $scriptArgs | ForEach-Object {
            if ([string]$_ -match "\s") {
                '"{0}"' -f $_
            }
            else {
                $_
            }
        }
        $backendPathForLog = Join-Path $PSScriptRoot "studio-display-brightness.ps1"
        $debugCommand = "{0} {1}" -f $backendPathForLog, ($renderedArgs -join " ")
        Write-UiLog -Message ("UI build={0} error: {1}" -f $script:UiBuildId, $_.Exception.Message)
        throw "$($_.Exception.Message)`nCommand: $debugCommand`nUI build: $script:UiBuildId"
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

function Get-SelectorArgs {
    param([pscustomobject]$Display)

    $selector = @{}
    $serial = [string]$Display.Serial
    if (-not [string]::IsNullOrWhiteSpace($serial) -and $serial -ne "unknown") {
        $selector["Serial"] = $serial
        return $selector
    }

    return $selector
}

function Get-BrightnessForDisplay {
    param([pscustomobject]$Display)

    $selector = Get-SelectorArgs -Display $Display
    $lines = Invoke-Backend -Command "get" @selector
    foreach ($line in $lines) {
        if ($line -match 'brightness=(?<value>\d+)%') {
            $parsed = [int]$Matches["value"]
            return [Math]::Max(0, [Math]::Min(100, $parsed))
        }
    }

    throw "Could not parse brightness from backend output."
}

function Invoke-BrightnessDelta {
    param(
        [ValidateSet("inc", "dec")]
        [string]$Direction,
        [int]$Amount,
        [hashtable]$Selector
    )

    $remaining = [Math]::Max(0, $Amount)
    while ($remaining -gt 0) {
        $step = [Math]::Min(100, $remaining)
        if ($step -lt 1) {
            break
        }

        $null = Invoke-Backend -Command $Direction -Value $step @Selector
        $remaining -= $step
    }
}

function Set-BrightnessForDisplay {
    param(
        [pscustomobject]$Display,
        [int]$Value
    )

    $selector = Get-SelectorArgs -Display $Display
    $target = [Math]::Max(0, [Math]::Min(100, $Value))

    try {
        $null = Invoke-Backend -Command "set" -Value $target @selector
        return
    }
    catch {
        # Fallback for environments where set binding is unreliable.
    }

    $current = Get-BrightnessForDisplay -Display $Display

    if ($target -eq $current) {
        return
    }

    if ($target -gt $current) {
        $step = $target - $current
        Invoke-BrightnessDelta -Direction "inc" -Amount $step -Selector $selector
    }
    else {
        $step = $current - $target
        Invoke-BrightnessDelta -Direction "dec" -Amount $step -Selector $selector
    }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "Studio Display Brightness ($script:UiBuildId)"
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

function Report-UiError {
    param([string]$Message)

    Set-Status -Message $Message -IsError $true

    Write-UiLog -Message ("UI build={0} modal-error: {1}" -f $script:UiBuildId, $Message)

    [void][System.Windows.Forms.MessageBox]::Show(
        "$Message`n`nFull log: $script:ErrorLogPath",
        "Studio Display Brightness Error",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    )
}

function Refresh-CurrentBrightness {
    $selected = Get-SelectedDisplay
    if ($null -eq $selected) {
        return
    }

    try {
        $brightness = Get-BrightnessForDisplay -Display $selected
        $brightnessSlider.Value = [Math]::Max(0, [Math]::Min(100, $brightness))
        $valueLabel.Text = "$brightness%"
    }
    catch {
        Report-UiError -Message $_.Exception.Message
    }
}

function Sync-StartupBrightness {
    $selected = Get-SelectedDisplay
    if ($null -eq $selected) {
        return
    }

    try {
        $startupBrightness = Get-BrightnessForDisplay -Display $selected
        $startupBrightness = [Math]::Max(0, [Math]::Min(100, $startupBrightness))

        $brightnessSlider.Value = $startupBrightness
        $valueLabel.Text = "$startupBrightness%"

        Set-BrightnessForDisplay -Display $selected -Value $startupBrightness
        Refresh-CurrentBrightness
        Set-Status -Message ("Startup brightness synced at {0}%" -f $startupBrightness)
    }
    catch {
        Report-UiError -Message $_.Exception.Message
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
        Report-UiError -Message $_.Exception.Message
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
        Set-BrightnessForDisplay -Display $selected -Value $brightnessSlider.Value
        Refresh-CurrentBrightness
        Set-Status -Message ("Applied brightness {0}%" -f $brightnessSlider.Value)
    }
    catch {
        Report-UiError -Message $_.Exception.Message
    }
})

$form.Add_Shown({
    Write-UiLog -Message ("UI build={0} startup backend={1}" -f $script:UiBuildId, (Join-Path $PSScriptRoot "studio-display-brightness.ps1"))
    Reload-Displays
    Sync-StartupBrightness
})

[void]$form.ShowDialog()
