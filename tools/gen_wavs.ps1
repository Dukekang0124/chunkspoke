param([string]$OutDir = 'D:\tmp\tts_wav', [string]$Manifest = 'D:\tmp\sent_manifest.json')
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$items = Get-Content $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
Add-Type -AssemblyName System.Speech
$fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
$probe = New-Object System.Speech.Synthesis.SpeechSynthesizer
$names = @($probe.GetInstalledVoices() | ForEach-Object { $_.VoiceInfo.Name })
$probe.Dispose()
Write-Output ("voices: " + ($names -join ' | '))
$use = @($names | Select-Object -First 2)
$done = 0
foreach ($v in $use) {
  $vshort = ($v -replace '\s+', '')
  $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $synth.SelectVoice($v)
  foreach ($it in $items) {
    foreach ($rate in $it.rates) {
      $path = Join-Path $OutDir ("{0}_{1}_r{2}.wav" -f $it.id, $vshort, $rate)
      if (Test-Path $path) { continue }
      $synth.Rate = $rate
      $synth.SetOutputToWaveFile($path, $fmt)
      $synth.Speak($it.text)
      $synth.SetOutputToNull()
      $done++
    }
  }
  $synth.Dispose()
}
Write-Output "synthesized $done files"
