while ($true) {
  $s = Get-Content "C:\Users\jasmi\Desktop\harvestbench\logs\thinkpilot_status.txt" -ErrorAction SilentlyContinue
  if ($s -match "deepseek.*mult=1\.0 DONE") {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" |
      Where-Object { $_.CommandLine -like "*pilot_thinking*deepseek*" } |
      ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
    Add-Content "C:\Users\jasmi\Desktop\harvestbench\logs\thinkpilot_status.txt" "WATCHER: killed deepseek before x10"
    break
  }
  Start-Sleep -Seconds 30
}
