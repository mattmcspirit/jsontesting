param (
    [Parameter(Mandatory)]
    [string]$userName,
    [string]$port = 443
)

$downloadPath = "C:\Users\$UserName\Downloads\WindowsAdminCenter.msi"
Invoke-WebRequest 'http://aka.ms/WACDownload' -OutFile $downloadPath
msiexec /i $downloadPath /qn /L*v log.txt SME_PORT=$port SSL_CERTIFICATE_OPTION=generate