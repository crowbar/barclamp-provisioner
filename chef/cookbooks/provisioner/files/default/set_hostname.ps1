$CrowbarAdminIP=(Get-ItemProperty "HKLM:\SOFTWARE\Crowbar" -Name Address).Address
$cards = Get-WmiObject win32_networkadapter
foreach ($card in $cards)
{
  $ipaddr = Get-WmiObject win32_networkadapterconfiguration -Filter "index = $($card.Index)" 
  if ($ipaddr.DHCPServer -eq $CrowbarAdminIP)
  {
    Write-Host "Found it! Mac addr is: $($card.MACAddress) and IP addr is: $($ipaddr.IPAddress)"
    $hostname = $card.MACAddress -replace ":", "-"
    $hostname = "d$($hostname.ToLower())"
    Write-Host $hostname
    $systeminfo = Get-WmiObject -Class Win32_ComputerSystem
    $result = $systeminfo.Rename($hostname)
    break
  }
}
