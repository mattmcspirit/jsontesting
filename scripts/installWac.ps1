param 
(
    [Parameter(Mandatory)]
    [System.Management.Automation.PSCredential]$Admincreds,
    [Int]$port = 443
)


$downloadPath = "C:\Users\$($Admincreds.UserName)\Downloads\WindowsAdminCenter.msi"
Invoke-WebRequest 'http://aka.ms/WACDownload' -OutFile $downloadPath
msiexec /i $downloadPath /qn /L*v log.txt SME_PORT=$port SSL_CERTIFICATE_OPTION=generate