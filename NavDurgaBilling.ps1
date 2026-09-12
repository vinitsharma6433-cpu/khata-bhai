# ============================================================================
#  Nav Durga Sports - Billing Software (New Replacement Software)
#  Reads LIVE data (read-only) from the existing rough2025 DATA folder:
#     ac_maste.dbf  -> Customers      product.dbf -> Products
#     bill.dbf      -> only to continue the Bill Number sequence
#  Anything NEW created in this software (bills, new customers, new products)
#  is stored separately under NewSoftware\data\*.json
#  so the original 10-year-old DBF files are NEVER modified.
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Start-Process powershell -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================================
#  DBF READER (dynamic)
# ============================================================================
function Read-DbfStructure {
    param([string]$Path)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $reader = New-Object System.IO.BinaryReader($stream)
    $header = $reader.ReadBytes(32)
    $nrec = [BitConverter]::ToUInt32($header, 4)
    $hlen = [BitConverter]::ToUInt16($header, 8)
    $rlen = [BitConverter]::ToUInt16($header, 10)
    $fields = @()
    $offset = 1
    while ($stream.Position -lt ($hlen - 1)) {
        $fd = $reader.ReadBytes(32)
        if ($fd[0] -eq 0x0D) { break }
        $name = [System.Text.Encoding]::ASCII.GetString($fd, 0, 11).TrimEnd([char]0)
        $type = [char]$fd[11]
        $len  = $fd[16]
        $dec  = $fd[17]
        $fields += [PSCustomObject]@{ Name=$name; Type=$type; Length=$len; Decimals=$dec; Offset=$offset }
        $offset += $len
    }
    $reader.Close(); $stream.Close()
    return [PSCustomObject]@{ NumRecords=$nrec; HeaderLen=$hlen; RecordLen=$rlen; Fields=$fields }
}

function Get-DbfRecords {
    param([string]$Path, [PSCustomObject]$Structure)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $reader = New-Object System.IO.BinaryReader($stream)
    $stream.Seek($Structure.HeaderLen, [System.IO.SeekOrigin]::Begin) | Out-Null
    $enc = [System.Text.Encoding]::GetEncoding("ISO-8859-1")
    $records = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Structure.NumRecords; $i++) {
        $rec = $reader.ReadBytes($Structure.RecordLen)
        if ($rec.Length -lt $Structure.RecordLen) { break }
        if ($rec[0] -eq 0x2A) { continue }
        $obj = [ordered]@{}
        foreach ($f in $Structure.Fields) {
            $raw = $enc.GetString($rec, $f.Offset, $f.Length)
            $val = $raw.Trim()
            if (($f.Type -eq 'N' -or $f.Type -eq 'F') -and $val -ne '') {
                [double]$num = 0
                if ([double]::TryParse($val, [ref]$num)) { $val = $num } else { $val = 0 }
            }
            $obj[$f.Name] = $val
        }
        $records.Add([PSCustomObject]$obj)
    }
    $reader.Close(); $stream.Close()
    return $records
}

function Read-JsonArray {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return @() }
    $raw = Get-Content $Path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $data = $raw | ConvertFrom-Json
    if ($null -eq $data) { return @() }
    return @($data)
}

function Save-JsonArray {
    param([string]$Path, $ArrayData)
    $arr = @($ArrayData)
    # NOTE: piping an array into ConvertTo-Json unrolls it element-by-element, so a
    # single-item array gets serialized as a bare JSON object instead of [ {...} ].
    # Passing it via -InputObject keeps it as one array value, which always serializes
    # correctly as a JSON array even when it has 0 or 1 items.
    (ConvertTo-Json -InputObject $arr -Depth 8) | Out-File -FilePath $Path -Encoding UTF8
}

# ============================================================================
#  AUDIT TRAIL (LOG SYSTEM)
#  Every create/edit/delete of a Bill, Customer, Product, or Voucher gets a
#  timestamped entry so Vineet can always answer "kisne kab kya badla".
# ============================================================================
function Add-AuditLog {
    param([string]$Action, [string]$Entity, [string]$Details)
    try {
        $existing = @(Read-JsonArray $AuditLogFile)
        $existing += [PSCustomObject]@{
            Timestamp = (Get-Date -Format "dd-MM-yyyy HH:mm:ss")
            User      = $env:USERNAME
            Action    = $Action
            Entity    = $Entity
            Details   = $Details
        }
        # Purani entries hamesha ke liye na badhti rahein - last 5000 tak rakho
        if ($existing.Count -gt 5000) { $existing = $existing[($existing.Count - 5000)..($existing.Count - 1)] }
        Save-JsonArray $AuditLogFile $existing
    } catch { }
}

# ============================================================================
#  AUTOMATIC BACKUP
#  Har din pehli baar app khulne par (aur Housekeeping se manually bhi) sabhi
#  NewSoftware\data\*.json files ek zip mein Backup folder mein save ho jaate
#  hain. Purani DBF files (asli data) yahan touch tak nahi hoti.
# ============================================================================
function Backup-AppData {
    param([switch]$Silent)
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        if (-not (Test-Path $BackupFolder)) { New-Item -ItemType Directory -Path $BackupFolder | Out-Null }
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $zipPath = Join-Path $BackupFolder "Backup_$stamp.zip"
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force }
        [System.IO.Compression.ZipFile]::CreateFromDirectory($NewDataFolder, $zipPath)
        # Sirf last 30 backups rakho, purane apne aap hat jaayenge
        $allBackups = Get-ChildItem $BackupFolder -Filter "Backup_*.zip" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
        if ($allBackups.Count -gt 30) {
            $allBackups | Select-Object -Skip 30 | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show("Backup ho gaya:`n$zipPath", "Nav Durga Sports - Backup", "OK", "Information") | Out-Null
        }
        return $zipPath
    } catch {
        if (-not $Silent) {
            [System.Windows.Forms.MessageBox]::Show("Backup fail hua:`n$($_.Exception.Message)", "Nav Durga Sports - Backup", "OK", "Error") | Out-Null
        }
        return $null
    }
}

# ============================================================================
#  PATHS
# ============================================================================
$RootPath = Split-Path -Parent $PSCommandPath
$BasePath = Split-Path -Parent $RootPath
$DataPath = Join-Path $BasePath "DATA"
$NewDataFolder = Join-Path $RootPath "data"
if (-not (Test-Path $NewDataFolder)) { New-Item -ItemType Directory -Path $NewDataFolder | Out-Null }
$BillsFile        = Join-Path $NewDataFolder "bills.json"
$NewCustFile      = Join-Path $NewDataFolder "customers_new.json"
$NewProdFile      = Join-Path $NewDataFolder "products_new.json"
$PurchaseVouchersFile = Join-Path $NewDataFolder "purchase_vouchers.json"
$StockOpeningFile = Join-Path $NewDataFolder "stock_opening.json"
$AuditLogFile     = Join-Path $NewDataFolder "audit_log.json"
$CustomerOverridesFile = Join-Path $NewDataFolder "customer_overrides.json"
# 2026-09-11 (session 15): Cash Recd./Cash Payment Vouchers + simple Masters
# (Group/Unit/State/GST) - same "own JSON file, DBF never touched" pattern as
# everything else in this app.
$CashReceiptsFile = Join-Path $NewDataFolder "cash_receipts.json"
$CashPaymentsFile = Join-Path $NewDataFolder "cash_payments.json"
$GroupMasterFile  = Join-Path $NewDataFolder "groups.json"
$UnitMasterFile   = Join-Path $NewDataFolder "units.json"
$StateMasterFile  = Join-Path $NewDataFolder "states.json"
$GstMasterFile    = Join-Path $NewDataFolder "gst_rates.json"
foreach ($f in @($BillsFile, $NewCustFile, $NewProdFile, $PurchaseVouchersFile, $StockOpeningFile, $AuditLogFile, $CustomerOverridesFile, $CashReceiptsFile, $CashPaymentsFile, $GroupMasterFile, $UnitMasterFile, $StateMasterFile, $GstMasterFile)) {
    if (-not (Test-Path $f)) { "[]" | Out-File -FilePath $f -Encoding UTF8 }
}
# 2026-09-11 (session 21): app khulte hi Login lock - password login_config.json
# mein save hota hai, default 2575. Housekeeping > Change Password se badla ja
# sakta hai.
$LoginConfigFile  = Join-Path $NewDataFolder "login_config.json"
if (-not (Test-Path $LoginConfigFile)) {
    (@{ Password = "2575" } | ConvertTo-Json) | Set-Content -Path $LoginConfigFile -Encoding UTF8
}
function Get-AppPassword {
    try {
        $cfg = Get-Content $LoginConfigFile -Raw | ConvertFrom-Json
        return "$($cfg.Password)"
    } catch {
        return "2575"
    }
}
function Set-AppPassword {
    param([string]$NewPassword)
    (@{ Password = $NewPassword } | ConvertTo-Json) | Set-Content -Path $LoginConfigFile -Encoding UTF8
}

# WhatsApp ke liye asli bill/statement ki image yahan banti hai, taaki sirf
# text ki jagah wahi bill/report bheja ja sake jo print hota hai.
$WhatsAppBillsFolder = Join-Path $RootPath "WhatsAppBills"
if (-not (Test-Path $WhatsAppBillsFolder)) { New-Item -ItemType Directory -Path $WhatsAppBillsFolder | Out-Null }

# 2026-09-11 (session 19): shared WhatsApp Auto-Send Daemon (Node.js,
# optional) - ONE folder used by BOTH Part 1 and Part 2, so only one
# WhatsApp QR-scan/session is ever needed. If Vineet has run
# "Start WhatsApp Auto.bat" and it's currently alive (heartbeat.txt fresh),
# Send-WhatsAppMessage below sends fully automatically (no browser, no
# click) by dropping a small job file in the queue folder; otherwise it
# falls back to the existing WhatsApp Web + clipboard Ctrl+V flow exactly
# as before - nothing breaks for anyone who hasn't set the daemon up.
$WhatsAppAutoFolder = "F:\rvineet25\NewSoftware\WhatsAppAuto"
$WhatsAppQueueFolder = Join-Path $WhatsAppAutoFolder "queue"
$WhatsAppHeartbeatFile = Join-Path $WhatsAppAutoFolder "heartbeat.txt"

# 2026-09-11 (session 20): software khulte hi WhatsApp Auto Daemon khud
# start ho jaata hai (agar pehle se chalu nahi hai - Part 1/Part 2 ki
# doosri copy se, ya khud Vineet ne .bat chala rakhi ho), aur software
# band hone par khud hi band bhi ho jaata hai. Agar daemon pehle se kisi
# aur se chalu mila to yahan chheda nahi jaata (na dobara start, na band).
$script:WeStartedWhatsAppDaemon = $false
$script:WhatsAppDaemonProcess = $null
function Start-WhatsAppDaemonIfNeeded {
    try {
        $alreadyRunning = $false
        if (Test-Path $WhatsAppHeartbeatFile) {
            try {
                $hbMs = [long]("$(Get-Content $WhatsAppHeartbeatFile -Raw -ErrorAction Stop)".Trim())
                $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
                if (($nowMs - $hbMs) -lt 30000) { $alreadyRunning = $true }
            } catch { $alreadyRunning = $false }
        }
        if ($alreadyRunning) { return }
        $batPath = Join-Path $WhatsAppAutoFolder "Start WhatsApp Auto.bat"
        if (-not (Test-Path $batPath)) { return }
        $script:WhatsAppDaemonProcess = Start-Process -FilePath $batPath -WorkingDirectory $WhatsAppAutoFolder -WindowStyle Minimized -PassThru
        $script:WeStartedWhatsAppDaemon = $true
    } catch { }
}
function Stop-WhatsAppDaemonIfWeStartedIt {
    try {
        if ($script:WeStartedWhatsAppDaemon -and $script:WhatsAppDaemonProcess -and -not $script:WhatsAppDaemonProcess.HasExited) {
            Start-Process -FilePath "taskkill.exe" -ArgumentList "/PID $($script:WhatsAppDaemonProcess.Id) /T /F" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
        }
    } catch { }
}
Start-WhatsAppDaemonIfNeeded

# Auto Backup - din mein pehli baar app khulne par khud-ba-khud backup zip ban
# jaata hai (silent, koi popup nahi). Manually "Housekeeping -> Backup Now" se
# bhi kabhi bhi liya ja sakta hai.
$BackupFolder = Join-Path $RootPath "Backup"
if (-not (Test-Path $BackupFolder)) { New-Item -ItemType Directory -Path $BackupFolder | Out-Null }
$LastBackupMarker = Join-Path $BackupFolder "last_auto_backup.txt"
try {
    $todayStr = Get-Date -Format "yyyy-MM-dd"
    $lastStr = if (Test-Path $LastBackupMarker) { Get-Content $LastBackupMarker -Raw } else { "" }
    if ($lastStr.Trim() -ne $todayStr) {
        Backup-AppData -Silent | Out-Null
        $todayStr | Out-File -FilePath $LastBackupMarker -Encoding UTF8
    }
} catch { }

# ============================================================================
#  LOAD OLD MASTER DATA (read-only)
# ============================================================================
try {
    $custStruct = Read-DbfStructure (Join-Path $DataPath "ac_maste.dbf")
    $script:OldCustomers = Get-DbfRecords (Join-Path $DataPath "ac_maste.dbf") $custStruct

    $prodStruct = Read-DbfStructure (Join-Path $DataPath "product.dbf")
    $script:OldProducts = Get-DbfRecords (Join-Path $DataPath "product.dbf") $prodStruct

    $billStruct = Read-DbfStructure (Join-Path $DataPath "bill.dbf")
    $script:OldBills = Get-DbfRecords (Join-Path $DataPath "bill.dbf") $billStruct

    # Cash/Bank receipts against parties - used to build the Party Ledger (khata)
    $crFile = Join-Path $DataPath "cashrecd.dbf"
    if (Test-Path $crFile) {
        $crStruct = Read-DbfStructure $crFile
        $script:OldReceipts = Get-DbfRecords $crFile $crStruct
    } else {
        $script:OldReceipts = @()
    }
}
catch {
    [System.Windows.Forms.MessageBox]::Show("Purana data (DATA folder) padhne me error aaya:`n$_", "Nav Durga Sports", "OK", "Error") | Out-Null
    exit
}

function Get-AllCustomers {
    $overrides = @{}
    foreach ($o in (Read-JsonArray $CustomerOverridesFile)) {
        $overrides["$($o.Code)".Trim()] = $o
    }
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($c in $script:OldCustomers) {
        if ("$($c.AC_NAME)".Trim() -eq "") { continue }
        $code = "$($c.AC_CODE)".Trim()
        $mob = "$($c.AC_MOB1)".Trim(); if ($mob -eq "") { $mob = "$($c.AC_MOB2)".Trim() }
        $city = "$($c.AC_CITY)".Trim(); $add1 = "$($c.AC_ADD1)".Trim(); $add2 = "$($c.AC_ADD2)".Trim()
        # Old customers come from the read-only DBF - agar unka mobile/city/address
        # blank ho ya update karna ho, to "Edit" se yeh override save hota hai
        # (data\customer_overrides.json mein), DBF file kabhi nahi chhedi jaati.
        $state = ""; $pin = ""; $gstin = ""; $contact = ""; $transport = ""; $landline = ""; $email = ""
        if ($overrides.ContainsKey($code)) {
            $ov = $overrides[$code]
            if ("$($ov.Mobile)".Trim() -ne "") { $mob = "$($ov.Mobile)".Trim() }
            if ("$($ov.City)".Trim() -ne "") { $city = "$($ov.City)".Trim() }
            if ("$($ov.Add1)".Trim() -ne "") { $add1 = "$($ov.Add1)".Trim() }
            if ("$($ov.Add2)".Trim() -ne "") { $add2 = "$($ov.Add2)".Trim() }
            $state = "$($ov.State)".Trim(); $pin = "$($ov.PinCode)".Trim(); $gstin = "$($ov.GSTIN)".Trim()
            $contact = "$($ov.ContactPerson)".Trim(); $transport = "$($ov.TransportName)".Trim()
            $landline = "$($ov.Landline)".Trim(); $email = "$($ov.Email)".Trim()
        }
        $list.Add([PSCustomObject]@{
            Code = $code; Name = "$($c.AC_NAME)".Trim(); City = $city
            Mobile = $mob; Add1 = $add1; Add2 = $add2; Source = "Old"
            State = $state; PinCode = $pin; GSTIN = $gstin; ContactPerson = $contact
            TransportName = $transport; Landline = $landline; Email = $email
        })
    }
    foreach ($c in (Read-JsonArray $NewCustFile)) {
        $list.Add([PSCustomObject]@{
            Code = $c.Code; Name = $c.Name; City = $c.City; Mobile = $c.Mobile
            Add1 = $c.Add1; Add2 = $c.Add2; Source = "New"
            State = "$($c.State)".Trim(); PinCode = "$($c.PinCode)".Trim(); GSTIN = "$($c.GSTIN)".Trim()
            ContactPerson = "$($c.ContactPerson)".Trim(); TransportName = "$($c.TransportName)".Trim()
            Landline = "$($c.Landline)".Trim(); Email = "$($c.Email)".Trim()
        })
    }
    return $list
}

# 2026-09-11 (session 16): billing screen (Rough Estimate) mein Mobile No.
# box editable hai, lekin agar Vineet wahan naya/sahi number type kare to
# pehle sirf usi bill ke record mein save hota tha - customer ke against
# kabhi save nahi hota tha, isliye agli baar wahi customer select karne par
# ya Party Ledger/Outstanding List mein number wapas gayab/purana dikhta tha.
# Yeh function customer ke asli record (naya customer -> customers_new.json,
# purana/DBF customer -> customer_overrides.json) mein Mobile save karta hai,
# taaki number hamesha ke liye "stick" ho jaaye.
function Save-CustomerMobileIfChanged {
    param([string]$CustCode, [string]$Mobile)
    try {
        $code = "$CustCode".Trim()
        $mob = "$Mobile".Trim()
        if ($code -eq "" -or $mob -eq "") { return }
        $cur = $script:AllCustomers | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
        if ($cur -and "$($cur.Mobile)".Trim() -eq $mob) { return }
        $newList = @(Read-JsonArray $NewCustFile)
        $inNew = $newList | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
        if ($inNew) {
            $newList = $newList | ForEach-Object {
                if ("$($_.Code)".Trim() -eq $code) {
                    [PSCustomObject]@{ Code = $_.Code; Name = $_.Name; City = $_.City; Mobile = $mob; Add1 = $_.Add1; Add2 = $_.Add2 }
                } else { $_ }
            }
            Save-JsonArray $NewCustFile $newList
        } else {
            $overrides = @(Read-JsonArray $CustomerOverridesFile)
            $existingOv = $overrides | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
            $city = if ($existingOv -and "$($existingOv.City)".Trim() -ne "") { "$($existingOv.City)" } elseif ($cur) { "$($cur.City)" } else { "" }
            $add1 = if ($existingOv -and "$($existingOv.Add1)".Trim() -ne "") { "$($existingOv.Add1)" } elseif ($cur) { "$($cur.Add1)" } else { "" }
            $add2 = if ($existingOv -and "$($existingOv.Add2)".Trim() -ne "") { "$($existingOv.Add2)" } elseif ($cur) { "$($cur.Add2)" } else { "" }
            $overrides = @($overrides | Where-Object { "$($_.Code)".Trim() -ne $code })
            $ovObj = [PSCustomObject]@{
                Code = $code; City = $city; Mobile = $mob; Add1 = $add1; Add2 = $add2
                State = $(if ($existingOv) { $existingOv.State } else { "" }); PinCode = $(if ($existingOv) { $existingOv.PinCode } else { "" })
                GSTIN = $(if ($existingOv) { $existingOv.GSTIN } else { "" }); ContactPerson = $(if ($existingOv) { $existingOv.ContactPerson } else { "" })
                TransportName = $(if ($existingOv) { $existingOv.TransportName } else { "" }); Landline = $(if ($existingOv) { $existingOv.Landline } else { "" })
                Email = $(if ($existingOv) { $existingOv.Email } else { "" })
            }
            $overrides = @($overrides) + $ovObj
            Save-JsonArray $CustomerOverridesFile $overrides
        }
        Add-AuditLog -Action "Edit" -Entity "Customer" -Details "$code - Mobile No. update: $mob (Bill/WhatsApp se)"
        $script:AllCustomers = Get-AllCustomers
    } catch { }
}

function Get-AllProducts {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in $script:OldProducts) {
        if ("$($p.PR_DESC)".Trim() -eq "") { continue }
        $list.Add([PSCustomObject]@{
            Code = "$($p.PR_CD)".Trim(); Desc = "$($p.PR_DESC)".Trim(); Desc2 = "$($p.PR_DESC2)".Trim()
            Rate = $p.PR_SRATE; Unit = "$($p.PR_UNIT)".Trim(); Gst = "$($p.PR_GST)".Trim(); Source = "Old"
        })
    }
    foreach ($p in (Read-JsonArray $NewProdFile)) {
        $list.Add([PSCustomObject]@{
            Code = $p.Code; Desc = $p.Desc; Desc2 = $p.Desc2; Rate = $p.Rate
            Unit = $p.Unit; Gst = $p.Gst; Source = "New"
        })
    }
    return $list
}

function Get-NextBillNo {
    $maxOld = 0
    foreach ($b in $script:OldBills) {
        $n = 0
        if ([int]::TryParse((($b.BL_NO) -replace '[^0-9]',''), [ref]$n)) { if ($n -gt $maxOld) { $maxOld = $n } }
    }
    $maxNew = 0
    foreach ($b in (Read-JsonArray $BillsFile)) {
        $n = 0
        if ([int]::TryParse(("$($b.BillNo)" -replace '[^0-9]',''), [ref]$n)) { if ($n -gt $maxNew) { $maxNew = $n } }
    }
    return [Math]::Max($maxOld, $maxNew) + 1
}

function Get-NextVoucherNo {
    $max = 0
    foreach ($v in (Read-JsonArray $PurchaseVouchersFile)) {
        $n = 0
        if ([int]::TryParse(("$($v.VoucherNo)" -replace '[^0-9]',''), [ref]$n)) { if ($n -gt $max) { $max = $n } }
    }
    return $max + 1
}

function Get-NextCashReceiptNo {
    $max = 0
    foreach ($v in (Read-JsonArray $CashReceiptsFile)) {
        $n = 0
        if ([int]::TryParse(("$($v.VoucherNo)" -replace '[^0-9]',''), [ref]$n)) { if ($n -gt $max) { $max = $n } }
    }
    return $max + 1
}

function Get-NextCashPaymentNo {
    $max = 0
    foreach ($v in (Read-JsonArray $CashPaymentsFile)) {
        $n = 0
        if ([int]::TryParse(("$($v.VoucherNo)" -replace '[^0-9]',''), [ref]$n)) { if ($n -gt $max) { $max = $n } }
    }
    return $max + 1
}

function Get-NextNewCode {
    param([string]$Prefix, [string]$JsonFile)
    $max = 0
    foreach ($item in (Read-JsonArray $JsonFile)) {
        $n = 0
        if ([int]::TryParse((("$($item.Code)") -replace "[^0-9]",''), [ref]$n)) { if ($n -gt $max) { $max = $n } }
    }
    return "{0}{1:D4}" -f $Prefix, ($max + 1)
}

# ============================================================================
#  PARTY LEDGER (KHATA) - matches the old "Ledger Account" report:
#  Opening Balance, then every Sale (bill.dbf, shown as "Rough Estimate No.xxx",
#  Debit) and every Receipt (cashrecd.dbf, Credit), sorted by date, with a
#  running Dr/Cr balance. Read-only - never writes to bill.dbf/cashrecd.dbf.
# ============================================================================
function ConvertTo-DbfDate {
    param($Raw)
    # DBF 'D' fields decode to an 8-char yyyyMMdd string (or blank)
    $s = "$Raw".Trim()
    if ($s.Length -ne 8) { return $null }
    $y = $s.Substring(0,4); $m = $s.Substring(4,2); $d = $s.Substring(6,2)
    try { return Get-Date -Year $y -Month $m -Day $d } catch { return $null }
}

function Get-CustomerLedger {
    param([string]$CustCode)

    $code = "$CustCode".Trim()
    $rows = New-Object System.Collections.Generic.List[object]
    if ($code -eq "") { return $rows }

    $cust = $script:OldCustomers | Where-Object { "$($_.AC_CODE)".Trim() -eq $code } | Select-Object -First 1
    $openBal = 0.0
    $openCrDb = "Dr"
    if ($cust) {
        [double]::TryParse("$($cust.AC_OPBAL)", [ref]$openBal) | Out-Null
        if ("$($cust.AC_CRDB)".Trim().ToUpper() -eq "C") { $openCrDb = "Cr" }
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($b in $script:OldBills) {
        if ("$($b.BL_CUCD)".Trim() -ne $code) { continue }
        $dt = ConvertTo-DbfDate $b.BL_DATE
        if (-not $dt) { continue }
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "SL$($b.BL_NO)"
            Particulars = "Rough Estimate No.$($b.BL_NO)"
            Debit = [double]$b.BL_NET; Credit = 0.0
        })
    }
    foreach ($r in $script:OldReceipts) {
        if ("$($r.CR_CUCD)".Trim() -ne $code) { continue }
        $dt = ConvertTo-DbfDate $r.CR_DATE
        if (-not $dt) { continue }
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "CR$($r.CR_NO)"
            Particulars = "$($r.CR_NARR)".Trim()
            Debit = 0.0; Credit = [double]$r.CR_AMT
        })
    }
    # New bills saved in this software (JSON) also count towards the khata
    foreach ($nb in (Read-JsonArray $BillsFile)) {
        $nbCode = ($nb.CustomerText -split ' - ')[0]
        if ("$nbCode".Trim() -ne $code) { continue }
        $dt = $null
        try { $dt = [DateTime]::ParseExact($nb.BillDate, "dd-MM-yyyy", $null) } catch { $dt = $null }
        if (-not $dt) { continue }
        $net = 0.0; [double]::TryParse("$($nb.NetAmount)", [ref]$net) | Out-Null
        $nbType = "$($nb.BillType)".Trim(); if ($nbType -eq "") { $nbType = "Rough Estimate" }
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "N$($nb.BillNo)"
            Particulars = "$nbType No.$($nb.BillNo)"
            Debit = $net; Credit = 0.0
        })
    }
    # Purchase Vouchers saved against this account show as Credit (we owe the supplier)
    foreach ($pv in (Read-JsonArray $PurchaseVouchersFile)) {
        $pvCode = ("$($pv.AccountText)" -split ' - ')[0]
        if ("$pvCode".Trim() -ne $code) { continue }
        $dt = $null
        try { $dt = [DateTime]::ParseExact($pv.VoucherDate, "dd-MM-yyyy", $null) } catch { $dt = $null }
        if (-not $dt) { continue }
        $amt = 0.0; [double]::TryParse("$($pv.Amount)", [ref]$amt) | Out-Null
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "PV$($pv.VoucherNo)"
            Particulars = "Purchase Voucher No.$($pv.VoucherNo)"
            Debit = 0.0; Credit = $amt
        })
    }
    # 2026-09-11 (session 15): Cash Recd. Voucher = money received from this
    # party -> Credit (reduces what they owe), same treatment as an old
    # cashrecd.dbf receipt above.
    foreach ($cr in (Read-JsonArray $CashReceiptsFile)) {
        $crCode = ("$($cr.AccountText)" -split ' - ')[0]
        if ("$crCode".Trim() -ne $code) { continue }
        $dt = $null
        try { $dt = [DateTime]::ParseExact($cr.VoucherDate, "dd-MM-yyyy", $null) } catch { $dt = $null }
        if (-not $dt) { continue }
        $amt = 0.0; [double]::TryParse("$($cr.Amount)", [ref]$amt) | Out-Null
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "CRV$($cr.VoucherNo)"
            Particulars = "Cash Recd. Voucher No.$($cr.VoucherNo)"
            Debit = 0.0; Credit = $amt
        })
    }
    # Cash Payment Voucher = money paid out to this party -> Debit (reduces
    # what we owe them / increases what they owe us), mirror of Purchase Voucher.
    foreach ($cp in (Read-JsonArray $CashPaymentsFile)) {
        $cpCode = ("$($cp.AccountText)" -split ' - ')[0]
        if ("$cpCode".Trim() -ne $code) { continue }
        $dt = $null
        try { $dt = [DateTime]::ParseExact($cp.VoucherDate, "dd-MM-yyyy", $null) } catch { $dt = $null }
        if (-not $dt) { continue }
        $amt = 0.0; [double]::TryParse("$($cp.Amount)", [ref]$amt) | Out-Null
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "CPV$($cp.VoucherNo)"
            Particulars = "Cash Payment Voucher No.$($cp.VoucherNo)"
            Debit = $amt; Credit = 0.0
        })
    }

    $entries = $entries | Sort-Object Date, VouNo

    $bal = $openBal
    if ($openCrDb -eq "Cr") { $bal = -$openBal }
    $openBalStr = "{0:N2} {1}" -f $openBal, $openCrDb
    $openRow = [PSCustomObject]@{
        Date = ""; VouNo = ""; Particulars = "Opening Balance"
        Debit = ""; Credit = ""; Balance = $openBalStr
    }
    $rows.Add($openRow)
    foreach ($e in $entries) {
        $bal = $bal + $e.Debit - $e.Credit
        $crdr = "Dr"
        if ($bal -lt 0) { $crdr = "Cr" }
        $debitStr = ""
        if ($e.Debit -gt 0) { $debitStr = $e.Debit.ToString("N2") }
        $creditStr = ""
        if ($e.Credit -gt 0) { $creditStr = $e.Credit.ToString("N2") }
        $balStr = "{0:N2} {1}" -f [Math]::Abs($bal), $crdr
        $rowObj = [PSCustomObject]@{
            Date = $e.Date.ToString("dd/MM/yyyy"); VouNo = $e.VouNo; Particulars = $e.Particulars
            Debit = $debitStr; Credit = $creditStr; Balance = $balStr
        }
        $rows.Add($rowObj)
    }
    return $rows
}

# ============================================================================
#  CUSTOMER STATEMENT - CUSTOM DATE RANGE
#  Same data/maths as Get-CustomerLedger (full history), lekin sirf ek date
#  range dikhata hai - jo bhi entries FromDate se pehle hain unka total
#  "Opening Balance (as on <FromDate>)" mein carry-forward ho jaata hai, taaki
#  balance hamesha sahi rahe chahe koi bhi date range chuni ho.
# ============================================================================
function Get-CustomerLedgerRange {
    param([string]$CustCode, [DateTime]$FromDate, [DateTime]$ToDate)

    $code = "$CustCode".Trim()
    $rows = New-Object System.Collections.Generic.List[object]
    if ($code -eq "") { return $rows }

    $cust = $script:OldCustomers | Where-Object { "$($_.AC_CODE)".Trim() -eq $code } | Select-Object -First 1
    $openBal = 0.0
    $openCrDb = "Dr"
    if ($cust) {
        [double]::TryParse("$($cust.AC_OPBAL)", [ref]$openBal) | Out-Null
        if ("$($cust.AC_CRDB)".Trim().ToUpper() -eq "C") { $openCrDb = "Cr" }
    }

    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($b in $script:OldBills) {
        if ("$($b.BL_CUCD)".Trim() -ne $code) { continue }
        $dt = ConvertTo-DbfDate $b.BL_DATE
        if (-not $dt) { continue }
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "SL$($b.BL_NO)"
            Particulars = "Rough Estimate No.$($b.BL_NO)"
            Debit = [double]$b.BL_NET; Credit = 0.0
        })
    }
    foreach ($r in $script:OldReceipts) {
        if ("$($r.CR_CUCD)".Trim() -ne $code) { continue }
        $dt = ConvertTo-DbfDate $r.CR_DATE
        if (-not $dt) { continue }
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "CR$($r.CR_NO)"
            Particulars = "$($r.CR_NARR)".Trim()
            Debit = 0.0; Credit = [double]$r.CR_AMT
        })
    }
    foreach ($nb in (Read-JsonArray $BillsFile)) {
        $nbCode = ($nb.CustomerText -split ' - ')[0]
        if ("$nbCode".Trim() -ne $code) { continue }
        $dt = $null
        try { $dt = [DateTime]::ParseExact($nb.BillDate, "dd-MM-yyyy", $null) } catch { $dt = $null }
        if (-not $dt) { continue }
        $net = 0.0; [double]::TryParse("$($nb.NetAmount)", [ref]$net) | Out-Null
        $nbType = "$($nb.BillType)".Trim(); if ($nbType -eq "") { $nbType = "Rough Estimate" }
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "N$($nb.BillNo)"
            Particulars = "$nbType No.$($nb.BillNo)"
            Debit = $net; Credit = 0.0
        })
    }
    foreach ($pv in (Read-JsonArray $PurchaseVouchersFile)) {
        $pvCode = ("$($pv.AccountText)" -split ' - ')[0]
        if ("$pvCode".Trim() -ne $code) { continue }
        $dt = $null
        try { $dt = [DateTime]::ParseExact($pv.VoucherDate, "dd-MM-yyyy", $null) } catch { $dt = $null }
        if (-not $dt) { continue }
        $amt = 0.0; [double]::TryParse("$($pv.Amount)", [ref]$amt) | Out-Null
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "PV$($pv.VoucherNo)"
            Particulars = "Purchase Voucher No.$($pv.VoucherNo)"
            Debit = 0.0; Credit = $amt
        })
    }
    foreach ($cr in (Read-JsonArray $CashReceiptsFile)) {
        $crCode = ("$($cr.AccountText)" -split ' - ')[0]
        if ("$crCode".Trim() -ne $code) { continue }
        $dt = $null
        try { $dt = [DateTime]::ParseExact($cr.VoucherDate, "dd-MM-yyyy", $null) } catch { $dt = $null }
        if (-not $dt) { continue }
        $amt = 0.0; [double]::TryParse("$($cr.Amount)", [ref]$amt) | Out-Null
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "CRV$($cr.VoucherNo)"
            Particulars = "Cash Recd. Voucher No.$($cr.VoucherNo)"
            Debit = 0.0; Credit = $amt
        })
    }
    foreach ($cp in (Read-JsonArray $CashPaymentsFile)) {
        $cpCode = ("$($cp.AccountText)" -split ' - ')[0]
        if ("$cpCode".Trim() -ne $code) { continue }
        $dt = $null
        try { $dt = [DateTime]::ParseExact($cp.VoucherDate, "dd-MM-yyyy", $null) } catch { $dt = $null }
        if (-not $dt) { continue }
        $amt = 0.0; [double]::TryParse("$($cp.Amount)", [ref]$amt) | Out-Null
        $entries.Add([PSCustomObject]@{
            Date = $dt; VouNo = "CPV$($cp.VoucherNo)"
            Particulars = "Cash Payment Voucher No.$($cp.VoucherNo)"
            Debit = $amt; Credit = 0.0
        })
    }

    $entries = @($entries | Sort-Object Date, VouNo)

    $bal = $openBal
    if ($openCrDb -eq "Cr") { $bal = -$openBal }
    $beforeRange = @($entries | Where-Object { $_.Date.Date -lt $FromDate.Date })
    foreach ($e in $beforeRange) { $bal = $bal + $e.Debit - $e.Credit }

    $crdrOpen = if ($bal -ge 0) { "Dr" } else { "Cr" }
    $openLabel = "Opening Balance (as on $($FromDate.ToString('dd-MM-yyyy')))"
    $rows.Add([PSCustomObject]@{
        Date = ""; VouNo = ""; Particulars = $openLabel
        Debit = ""; Credit = ""; Balance = ("{0:N2} {1}" -f [Math]::Abs($bal), $crdrOpen)
    })

    $inRange = @($entries | Where-Object { $_.Date.Date -ge $FromDate.Date -and $_.Date.Date -le $ToDate.Date })
    foreach ($e in $inRange) {
        $bal = $bal + $e.Debit - $e.Credit
        $crdr = if ($bal -lt 0) { "Cr" } else { "Dr" }
        $debitStr = ""; if ($e.Debit -gt 0) { $debitStr = $e.Debit.ToString("N2") }
        $creditStr = ""; if ($e.Credit -gt 0) { $creditStr = $e.Credit.ToString("N2") }
        $balStr = "{0:N2} {1}" -f [Math]::Abs($bal), $crdr
        $rows.Add([PSCustomObject]@{
            Date = $e.Date.ToString("dd/MM/yyyy"); VouNo = $e.VouNo; Particulars = $e.Particulars
            Debit = $debitStr; Credit = $creditStr; Balance = $balStr
        })
    }
    return $rows
}

# ============================================================================
#  ALL PARTY CLOSING BALANCES (basis of Trial Balance)
#  Same maths as Get-CustomerLedger's running balance, but computed for every
#  party in ONE pass (instead of re-reading every JSON file per party), so the
#  Trial Balance report opens instantly even with hundreds of customers.
# ============================================================================
function Get-AllPartyBalances {
    $balances = @{}
    $names = @{}
    foreach ($c in $script:OldCustomers) {
        $code = "$($c.AC_CODE)".Trim(); if ($code -eq "") { continue }
        $ob = 0.0; [double]::TryParse("$($c.AC_OPBAL)", [ref]$ob) | Out-Null
        if ("$($c.AC_CRDB)".Trim().ToUpper() -eq "C") { $ob = -$ob }
        $balances[$code] = $ob
        $names[$code] = "$($c.AC_NAME)".Trim()
    }
    foreach ($b in $script:OldBills) {
        $code = "$($b.BL_CUCD)".Trim(); if ($code -eq "") { continue }
        if (-not $balances.ContainsKey($code)) { $balances[$code] = 0.0; $names[$code] = $code }
        $balances[$code] += [double]$b.BL_NET
    }
    foreach ($r in $script:OldReceipts) {
        $code = "$($r.CR_CUCD)".Trim(); if ($code -eq "") { continue }
        if (-not $balances.ContainsKey($code)) { $balances[$code] = 0.0; $names[$code] = $code }
        $balances[$code] -= [double]$r.CR_AMT
    }
    foreach ($nb in (Read-JsonArray $BillsFile)) {
        $code = ("$($nb.CustomerText)" -split ' - ')[0].Trim(); if ($code -eq "") { continue }
        if (-not $balances.ContainsKey($code)) { $balances[$code] = 0.0; $names[$code] = $code }
        $net = 0.0; [double]::TryParse("$($nb.NetAmount)", [ref]$net) | Out-Null
        $balances[$code] += $net
    }
    foreach ($pv in (Read-JsonArray $PurchaseVouchersFile)) {
        $code = ("$($pv.AccountText)" -split ' - ')[0].Trim(); if ($code -eq "") { continue }
        if (-not $balances.ContainsKey($code)) { $balances[$code] = 0.0; $names[$code] = $code }
        $amt = 0.0; [double]::TryParse("$($pv.Amount)", [ref]$amt) | Out-Null
        $balances[$code] -= $amt
    }
    foreach ($cr in (Read-JsonArray $CashReceiptsFile)) {
        $code = ("$($cr.AccountText)" -split ' - ')[0].Trim(); if ($code -eq "") { continue }
        if (-not $balances.ContainsKey($code)) { $balances[$code] = 0.0; $names[$code] = $code }
        $amt = 0.0; [double]::TryParse("$($cr.Amount)", [ref]$amt) | Out-Null
        $balances[$code] -= $amt
    }
    foreach ($cp in (Read-JsonArray $CashPaymentsFile)) {
        $code = ("$($cp.AccountText)" -split ' - ')[0].Trim(); if ($code -eq "") { continue }
        if (-not $balances.ContainsKey($code)) { $balances[$code] = 0.0; $names[$code] = $code }
        $amt = 0.0; [double]::TryParse("$($cp.Amount)", [ref]$amt) | Out-Null
        $balances[$code] += $amt
    }
    foreach ($nc in (Read-JsonArray $NewCustFile)) {
        $ncCode = "$($nc.Code)".Trim()
        if ($balances.ContainsKey($ncCode)) { $names[$ncCode] = "$($nc.Name)".Trim() }
    }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($code in $balances.Keys) {
        $bal = $balances[$code]
        if ([Math]::Abs($bal) -lt 0.005) { continue }
        $crdr = if ($bal -ge 0) { "Dr" } else { "Cr" }
        $result.Add([PSCustomObject]@{
            Code = $code; Name = $names[$code]; Amount = [Math]::Round([Math]::Abs($bal), 2); CrDr = $crdr
        })
    }
    return ($result | Sort-Object Code)
}

# ============================================================================
#  LOOK & FEEL
# ============================================================================
$FontNormal = New-Object System.Drawing.Font("Tahoma", 10)
$FontBold   = New-Object System.Drawing.Font("Tahoma", 10, [System.Drawing.FontStyle]::Bold)
$FontTitle  = New-Object System.Drawing.Font("Tahoma", 13, [System.Drawing.FontStyle]::Bold)
$FontMenu   = New-Object System.Drawing.Font("Tahoma", 14, [System.Drawing.FontStyle]::Bold)
$ColorVfpBlue = [System.Drawing.Color]::FromArgb(0, 0, 128)
$ColorGrid    = [System.Drawing.Color]::FromArgb(224, 224, 224)

function New-TitleBanner {
    param([string]$Text, [int]$Width)
    $pnl = New-Object System.Windows.Forms.Panel
    $pnl.Size = New-Object System.Drawing.Size($Width, 40)
    $pnl.Location = New-Object System.Drawing.Point(0, 0)
    $pnl.BackColor = $ColorVfpBlue
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $Text
    $lbl.ForeColor = [System.Drawing.Color]::White
    $lbl.Font = $FontTitle
    $lbl.AutoSize = $true
    $lbl.Location = New-Object System.Drawing.Point(12, 8)
    $pnl.Controls.Add($lbl)
    return $pnl
}

function Style-Grid {
    param($grid)
    $grid.BackgroundColor = [System.Drawing.Color]::White
    $grid.GridColor = [System.Drawing.Color]::Gainsboro
    $grid.Font = $FontNormal
    $grid.RowHeadersVisible = $false
    $grid.DefaultCellStyle.SelectionBackColor = $ColorVfpBlue
    $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $ColorVfpBlue
    $grid.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $grid.ColumnHeadersDefaultCellStyle.Font = $FontBold
    $grid.EnableHeadersVisualStyles = $false
    $grid.AutoSizeColumnsMode = "None"
    $grid.AllowUserToAddRows = $false
    $grid.ReadOnly = $true
    $grid.SelectionMode = "FullRowSelect"
    $grid.MultiSelect = $false
}

# ============================================================================
#  "CONTAINS" SEARCH FOR EDITABLE COMBOBOXES (2026-09-09 fix)
#  Windows' built-in AutoCompleteMode ("SuggestAppend") only ever matches from
#  the VERY START of the text (e.g. "0004 - Chatak Sports") - so typing a
#  customer/item's actual NAME (which never starts with its numeric code)
#  never matched anything, no matter how many words were typed. This makes
#  the dropdown's own Items list live-filter to anything CONTAINING the typed
#  text (case-insensitive, code OR name), same idea as a phone's search box.
# ============================================================================
function Enable-ComboBoxContainsSearch {
    param($Combo, [scriptblock]$GetAllItems)
    $Combo.AutoCompleteMode = "None"
    $filtering = $false
    $Combo.Add_TextChanged({
        if ($filtering) { return }
        $filtering = $true
        $typed = $Combo.Text
        # Rebuilding Items + forcing the dropdown open SYNCHRONOUSLY inside the
        # same TextChanged event that a keystroke just raised can re-enter the
        # Windows message loop while it's still busy handling that keystroke -
        # this is exactly the same class of bug that caused the 2026-09-09
        # double-click freeze (see the item grid's CellClick handler above), and
        # was found to freeze the WHOLE app (no click/close works, needs Task
        # Manager) when this search box was actually typed into. Fix: defer all
        # of it via BeginInvoke so it runs right AFTER the keystroke finishes
        # processing, never while the message loop is mid-keystroke.
        $action = [Action]{
            try {
                $t = $typed.Trim()
                $allItems = & $GetAllItems
                if ($t.Length -ge 1) {
                    $list = @($allItems | Where-Object { $_ -like "*$t*" } | Select-Object -First 40)
                } else {
                    $list = $allItems
                }
                # 2026-09-09 (round 2): rebuild Items and reassert the typed text +
                # cursor position AFTER everything (including DroppedDown), not
                # just before it - opening the dropdown can otherwise nudge the
                # editable combo's selection/highlight, which felt like "typing
                # gets interrupted / text gets selected" while typing fast.
                $curText = $Combo.Text
                $cursorPos = $Combo.SelectionStart
                $Combo.Items.Clear()
                [void]$Combo.Items.AddRange([string[]]$list)
                if ($Combo.Text -ne $curText) { $Combo.Text = $curText }
                if ($t.Length -ge 1 -and $list.Count -gt 0) {
                    # Dropdown ko band-kholo taaki naya (filtered) Items collection
                    # turant dikhe - sirf DroppedDown=$true karna kaafi nahi tha
                    # jab woh pehle se hi khula ho (list refresh nahi hoti thi).
                    $Combo.DroppedDown = $false
                    $Combo.DroppedDown = $true
                } elseif ($list.Count -eq 0) {
                    $Combo.DroppedDown = $false
                }
                if ($Combo.Text -ne $curText) { $Combo.Text = $curText }
                if ($cursorPos -gt $Combo.Text.Length) { $cursorPos = $Combo.Text.Length }
                $Combo.SelectionStart = $cursorPos
                $Combo.SelectionLength = 0
            } catch { }
            $filtering = $false
        }
        try { $Combo.BeginInvoke($action) | Out-Null } catch { $filtering = $false }
    }.GetNewClosure())
    # Box khaali ho aur usme click/Tab se aaye, to turant poori list dikha do -
    # taaki pata chale ki yahan search hai (sirf type karne par depend na kare).
    $Combo.Add_Enter({
        if ($Combo.Text.Trim() -eq "") {
            try {
                $allItems = & $GetAllItems
                $Combo.Items.Clear()
                [void]$Combo.Items.AddRange([string[]]$allItems)
                $Combo.DroppedDown = $true
            } catch { }
        }
    }.GetNewClosure())
}

# Same idea, but for a DataGridViewComboBoxColumn cell's editing control - that
# control only exists while a cell is actually being edited, so this hooks
# EditingControlShowing (fires each time editing starts) and wires the
# TextChanged filter only ONCE per control instance (DataGridView reuses the
# same ComboBox control for every cell in that column, so re-wiring on every
# edit would stack up duplicate handlers).
function Enable-GridComboContainsSearch {
    param($Grid, [System.Collections.Generic.List[string]]$AllItems)
    $Grid.Add_EditingControlShowing({
        param($s, $e)
        try {
            if ($e.Control -is [System.Windows.Forms.ComboBox]) {
                $cb = $e.Control
                $cb.AutoCompleteMode = "None"
                if ("$($cb.Tag)" -ne "SearchWired") {
                    $cb.Tag = "SearchWired"
                    $filtering = $false
                    $cb.Add_TextChanged({
                        if ($filtering) { return }
                        $filtering = $true
                        $typed = $cb.Text
                        # Same reentrancy risk as Enable-ComboBoxContainsSearch above
                        # (and worse here - this control lives inside a DataGridView
                        # cell edit, which is already known to be fragile around
                        # forcing a dropdown open, see the CellClick double-click
                        # fix). Defer everything via BeginInvoke so it never runs
                        # while the message loop is still mid-keystroke.
                        $action = [Action]{
                            try {
                                $t = $typed.Trim()
                                if ($t.Length -ge 1) {
                                    $found = @($AllItems | Where-Object { $_ -like "*$t*" } | Select-Object -First 40)
                                } else {
                                    $found = @($AllItems)
                                }
                                if ($found.Count -gt 0) {
                                    # same defensive text/cursor reassert as
                                    # Enable-ComboBoxContainsSearch above
                                    $curText = $cb.Text
                                    $cursorPos = $cb.SelectionStart
                                    $cb.Items.Clear()
                                    [void]$cb.Items.AddRange([string[]]$found)
                                    if ($cb.Text -ne $curText) { $cb.Text = $curText }
                                    if ($t.Length -ge 1) {
                                        $cb.DroppedDown = $false
                                        $cb.DroppedDown = $true
                                    }
                                    if ($cb.Text -ne $curText) { $cb.Text = $curText }
                                    if ($cursorPos -gt $cb.Text.Length) { $cursorPos = $cb.Text.Length }
                                    $cb.SelectionStart = $cursorPos
                                    $cb.SelectionLength = 0
                                }
                            } catch { }
                            $filtering = $false
                        }
                        try { $cb.BeginInvoke($action) | Out-Null } catch { $filtering = $false }
                    }.GetNewClosure())
                }
            }
        } catch { }
    })
}

function Send-WhatsAppMessage {
    param([string]$Mobile, [string]$Message, [string]$ImagePath = "")
    # 2026-09-11 (session 20): callers (e.g. Bill List's Resend WhatsApp)
    # check this flag right after calling this function to know whether
    # the send actually went out, so they can mark that bill "sent".
    $script:LastWhatsAppSendOk = $false
    $mob = $Mobile -replace '[^0-9]', ''
    if ($mob.Length -eq 10) { $mob = "91$mob" }
    elseif ($mob.Length -eq 11 -and $mob.StartsWith("0")) { $mob = "91" + $mob.Substring(1) }
    if ($mob.Length -lt 12) {
        [System.Windows.Forms.MessageBox]::Show("Valid mobile number nahi mila.`nMobile No. box mein poora 10 ank ka number likh kar dobara try karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null
        return
    }

    # 2026-09-11 (session 19): agar WhatsApp Auto Daemon abhi zinda hai
    # (heartbeat.txt daemon khud har ~8 second mein update karta hai - 30
    # second se purana matlab daemon band hai), to bilkul automatic bhej do:
    # koi browser nahi khulega, koi Ctrl+V nahi karna - bas ek chhoti job
    # file queue mein daal do, daemon khud utha kar bhej dega.
    $autoOk = $false
    if (Test-Path $WhatsAppHeartbeatFile) {
        try {
            $hbMs = [long]("$(Get-Content $WhatsAppHeartbeatFile -Raw -ErrorAction Stop)".Trim())
            $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            if (($nowMs - $hbMs) -lt 30000) { $autoOk = $true }
        } catch { $autoOk = $false }
    }
    if ($autoOk) {
        try {
            if (-not (Test-Path $WhatsAppQueueFolder)) { New-Item -ItemType Directory -Path $WhatsAppQueueFolder -Force | Out-Null }
            $job = [PSCustomObject]@{ Mobile = $mob; Message = $Message; ImagePath = $ImagePath }
            $jobFile = Join-Path $WhatsAppQueueFolder ("job_" + (Get-Date -Format "yyyyMMdd_HHmmss_fff") + ".json")
            ($job | ConvertTo-Json) | Set-Content -Path $jobFile -Encoding UTF8
            [System.Windows.Forms.MessageBox]::Show("WhatsApp message sent successfully.", "Nav Durga Sports", "OK", "Information") | Out-Null
            $script:LastWhatsAppSendOk = $true
            return
        } catch {
            # Queue mein likhne mein bhi fail ho jaye to neeche purane
            # (browser + clipboard) tarike par chale jao, kabhi message
            # "gayab" nahi hona chahiye.
        }
    }

    $encoded = [System.Uri]::EscapeDataString($Message)
    $url = "https://web.whatsapp.com/send?phone=$mob&text=$encoded"
    $launched = $false
    foreach ($exe in @("msedge", "chrome")) {
        try { Start-Process -FilePath $exe -ArgumentList $url -ErrorAction Stop; $launched = $true; break } catch { }
    }
    if (-not $launched) { Start-Process $url }
    # Asli bill/report ki image bhi bani hai (sirf text nahi) - WhatsApp Web
    # apne aap file attach nahi kar sakta (browser security, koi bhi software
    # isko bypass nahi kar sakta bina paid WhatsApp Business API ke). Sabse
    # chhota manual step yeh hai: image ko seedha clipboard par copy kar dena
    # (file nahi, asli image) - WhatsApp Web mein chat box click karke Ctrl+V
    # dabane se image seedhe attach ho jaati hai, File Explorer mein file
    # dhundhna/drag karna nahi padta (2026-09-11 session 18 - pehle File
    # Explorer + drag-drop tha, Vineet ke "seedha jana chahiye" feedback par
    # simplify kiya gaya).
    if ($ImagePath -and (Test-Path $ImagePath)) {
        $clipOk = $false
        try {
            $clipImg = [System.Drawing.Image]::FromFile($ImagePath)
            [System.Windows.Forms.Clipboard]::SetImage($clipImg)
            $clipImg.Dispose()
            $clipOk = $true
        } catch { $clipOk = $false }
        if ($clipOk) {
            [System.Windows.Forms.MessageBox]::Show("Asli bill/report ki image clipboard par copy ho gayi hai.`n`nWhatsApp Web ki chat (jahan message likha hai) mein click karke Ctrl+V dabaiye - image seedhe attach ho jayegi, phir Send (green arrow) button dabaiye.", "Nav Durga Sports - Ctrl+V Se Image Bhejein", "OK", "Information") | Out-Null
        } else {
            try { Start-Process "explorer.exe" -ArgumentList "/select,`"$ImagePath`"" } catch { }
            [System.Windows.Forms.MessageBox]::Show("Asli bill/report ki image taiyar hai:`n$ImagePath`n`nWhatsApp Web khul gaya hai - File Explorer mein image already select hai, usko seedha WhatsApp chat mein drag-drop kar dijiye (ya clip/attach icon se bhi bhej sakte hain).", "Nav Durga Sports - Image Attach Karein", "OK", "Information") | Out-Null
        }
    }
    $script:LastWhatsAppSendOk = $true
}

function Get-BillImage {
    # Bill/Rough Estimate ki EXACT wahi design (header, item table, totals box)
    # jo print/print-preview mein dikhti hai - lekin ek lambi single image ke
    # roop mein (pagination ki zaroorat nahi, image jitni lambi chahiye utni
    # ban jaati hai), taaki WhatsApp par asli bill bheja ja sake, sirf text nahi.
    param($Bill)
    try {
        $left = 30; $topStart = 30; $tableWidth = 740; $right = $left + $tableWidth

        $fontHeader = New-Object System.Drawing.Font("Arial", 18, [System.Drawing.FontStyle]::Bold)
        $fontSub    = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
        $fontNorm   = New-Object System.Drawing.Font("Arial", 10)
        $fontSmall  = New-Object System.Drawing.Font("Arial", 9)
        $fontTotal  = New-Object System.Drawing.Font("Arial", 11, [System.Drawing.FontStyle]::Bold)

        $black     = [System.Drawing.Brushes]::Black
        $navyColor = [System.Drawing.Color]::FromArgb(0, 0, 128)
        $navyBrush = New-Object System.Drawing.SolidBrush($navyColor)
        $navyPen   = New-Object System.Drawing.Pen($navyColor, 2)
        $blackPen  = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1.2)
        $grayPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::Gainsboro, 1)
        $headerFillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::LightGray)
        $totalsFillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 245, 250))

        $centerFmt = New-Object System.Drawing.StringFormat
        $centerFmt.Alignment = [System.Drawing.StringAlignment]::Center
        $rightFmt = New-Object System.Drawing.StringFormat
        $rightFmt.Alignment = [System.Drawing.StringAlignment]::Far
        $rightFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rightFmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $midFmt = New-Object System.Drawing.StringFormat
        $midFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $midFmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap

        $items = @($Bill.Items)
        $itemCount = $items.Count
        $headerRowH = 24; $rowH = 22
        $boxW = 260; $boxH = 98; $totalsGap = 20; $footerGap = 30; $footerH = 18

        # Layout heights are fixed/arithmetic (no text wrapping), so total image
        # height can be computed up-front before creating the bitmap.
        $y = $topStart + 12
        $y += 30 + 20 + 22 + 15   # header block (title/tagline/type/rule)
        $y += 22 + 20 + 20 + 20   # Bill No/Date, Customer, Address, Mobile
        $tableTop = $y
        $tableBottom = $tableTop + $headerRowH + ($itemCount * $rowH)
        $boxY = $tableBottom + $totalsGap
        $footerY = $boxY + $boxH + $footerGap
        $contentBottom = $footerY + $footerH
        $borderPad = 15
        $imgW = [int]($right + $borderPad + 30)
        $imgH = [int]($contentBottom + $borderPad + 30)

        $bmp = New-Object System.Drawing.Bitmap($imgW, $imgH)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::White)

        $yy = $topStart + 12
        $g.DrawString("VANI, MEERUT", $fontHeader, $navyBrush, (New-Object System.Drawing.RectangleF($left, $yy, $tableWidth, 28)), $centerFmt); $yy += 30
        $g.DrawString("DASH X - Cricket Tennis Balls", $fontSub, $black, (New-Object System.Drawing.RectangleF($left, $yy, $tableWidth, 18)), $centerFmt); $yy += 20
        $billTypeTitle = "ROUGH ESTIMATE"
        if ("$($Bill.BillType)".Trim() -eq "Tax Invoice") { $billTypeTitle = "TAX INVOICE" }
        $g.DrawString($billTypeTitle, $fontSub, $navyBrush, (New-Object System.Drawing.RectangleF($left, $yy, $tableWidth, 18)), $centerFmt); $yy += 22
        $g.DrawLine($navyPen, $left, $yy, $right, $yy); $yy += 15

        $custName = $Bill.CustomerText
        if ("$($Bill.CustomerText)" -match ' - ') { $custName = ("$($Bill.CustomerText)" -split ' - ', 2)[1] }
        $g.DrawString("Bill No: $($Bill.BillNo)", $fontNorm, $black, $left, $yy)
        $g.DrawString("Date: $($Bill.BillDate)", $fontNorm, $black, ($left + 390), $yy); $yy += 22
        $g.DrawString("Customer: $custName", $fontNorm, $black, $left, $yy); $yy += 20
        $g.DrawString("Address: $($Bill.Address), $($Bill.City)", $fontNorm, $black, $left, $yy); $yy += 20
        $g.DrawString("Mobile: $($Bill.Mobile)", $fontNorm, $black, $left, $yy); $yy += 20

        $colDescW = [Math]::Round($tableWidth * 0.52); $colQtyW = [Math]::Round($tableWidth * 0.10); $colRateW = [Math]::Round($tableWidth * 0.17)
        $cX0 = $left; $cX1 = $cX0 + $colDescW; $cX2 = $cX1 + $colQtyW; $cX3 = $cX2 + $colRateW; $cX4 = $right

        $g.FillRectangle($headerFillBrush, $cX0, $tableTop, $tableWidth, $headerRowH)
        $g.DrawString("Description", $fontSub, $black, (New-Object System.Drawing.RectangleF($cX0, $tableTop, ($cX1 - $cX0 - 6), $headerRowH)), $midFmt)
        $g.DrawString("Qty",    $fontSub, $black, (New-Object System.Drawing.RectangleF($cX1, $tableTop, ($cX2 - $cX1 - 6), $headerRowH)), $rightFmt)
        $g.DrawString("Rate",   $fontSub, $black, (New-Object System.Drawing.RectangleF($cX2, $tableTop, ($cX3 - $cX2 - 6), $headerRowH)), $rightFmt)
        $g.DrawString("Amount", $fontSub, $black, (New-Object System.Drawing.RectangleF($cX3, $tableTop, ($cX4 - $cX3 - 6), $headerRowH)), $rightFmt)

        $ry = $tableTop + $headerRowH
        foreach ($it in $items) {
            $g.DrawString("$($it.Description)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX0, $ry, ($cX1 - $cX0 - 6), $rowH)), $midFmt)
            $g.DrawString("$($it.Qty)",    $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX1, $ry, ($cX2 - $cX1 - 6), $rowH)), $rightFmt)
            $g.DrawString("$($it.Rate)",   $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX2, $ry, ($cX3 - $cX2 - 6), $rowH)), $rightFmt)
            $g.DrawString("$($it.Amount)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX3, $ry, ($cX4 - $cX3 - 6), $rowH)), $rightFmt)
            $ry += $rowH
            $g.DrawLine($grayPen, $cX0, $ry, $cX4, $ry)
        }

        $g.DrawRectangle($blackPen, $cX0, $tableTop, $tableWidth, ($tableBottom - $tableTop))
        $g.DrawLine($blackPen, $cX0, ($tableTop + $headerRowH), $cX4, ($tableTop + $headerRowH))
        foreach ($cx in @($cX1, $cX2, $cX3)) { $g.DrawLine($blackPen, $cx, $tableTop, $cx, $tableBottom) }

        $boxX = $right - $boxW
        $g.FillRectangle($totalsFillBrush, $boxX, $boxY, $boxW, $boxH)
        $g.DrawRectangle($blackPen, $boxX, $boxY, $boxW, $boxH)
        $labelW = 140; $valW = $boxW - $labelW - 20
        $ty = $boxY + 8

        $gstPctVal = 0.0; [double]::TryParse("$($Bill.GstPct)", [ref]$gstPctVal) | Out-Null
        $taxLabel = if ($gstPctVal -gt 0) { "Tax ($($Bill.GstPct)%):" } else { "Tax:" }

        $g.DrawString("Total:", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
        $g.DrawString("Rs. $($Bill.Total)", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt); $ty += 24

        $g.DrawString($taxLabel, $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
        $g.DrawString("Rs. $($Bill.GstAmt)", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt); $ty += 24
        $g.DrawLine($blackPen, ($boxX + 8), $ty, ($boxX + $boxW - 8), $ty); $ty += 6

        $g.DrawString("Net Amount:", $fontTotal, $navyBrush, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
        $g.DrawString("Rs. $($Bill.NetAmount)", $fontTotal, $navyBrush, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt)

        $g.DrawString("Thank you for your business!", $fontNorm, $black, (New-Object System.Drawing.RectangleF($left, $footerY, $tableWidth, $footerH)), $centerFmt)

        $g.DrawRectangle($navyPen, ($left - $borderPad), ($topStart - $borderPad), ($tableWidth + 2 * $borderPad), ($contentBottom - $topStart + 2 * $borderPad))

        if (-not (Test-Path $WhatsAppBillsFolder)) { New-Item -ItemType Directory -Path $WhatsAppBillsFolder | Out-Null }
        $safeBillNo = "$($Bill.BillNo)" -replace '[^A-Za-z0-9_-]', '_'
        $path = Join-Path $WhatsAppBillsFolder "Bill_$safeBillNo.png"
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        return $path
    } catch {
        try { [System.Windows.Forms.MessageBox]::Show("Bill ki image (parchi) banane mein error:`n$($_.Exception.Message)", "Nav Durga Sports - Error", "OK", "Error") | Out-Null } catch {}
        return $null
    }
}

function Show-BillPrintPreview {
    param($Bill)
    $doc = New-Object System.Drawing.Printing.PrintDocument
    $printState = @{ Index = 0 }
    $doc.add_BeginPrint({ $printState.Index = 0 }.GetNewClosure())
    $handler = {
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $fontHeader = New-Object System.Drawing.Font("Arial", 18, [System.Drawing.FontStyle]::Bold)
        $fontSub    = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
        $fontNorm   = New-Object System.Drawing.Font("Arial", 10)
        $fontSmall  = New-Object System.Drawing.Font("Arial", 9)
        $fontTotal  = New-Object System.Drawing.Font("Arial", 11, [System.Drawing.FontStyle]::Bold)

        $black     = [System.Drawing.Brushes]::Black
        $navyColor = [System.Drawing.Color]::FromArgb(0, 0, 128)
        $navyBrush = New-Object System.Drawing.SolidBrush($navyColor)
        $navyPen   = New-Object System.Drawing.Pen($navyColor, 2)
        $blackPen  = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1.2)
        $grayPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::Gainsboro, 1)
        $headerFillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::LightGray)
        $totalsFillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 245, 250))

        $centerFmt = New-Object System.Drawing.StringFormat
        $centerFmt.Alignment = [System.Drawing.StringAlignment]::Center
        $rightFmt = New-Object System.Drawing.StringFormat
        $rightFmt.Alignment = [System.Drawing.StringAlignment]::Far
        $rightFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rightFmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $midFmt = New-Object System.Drawing.StringFormat
        $midFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $midFmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap

        # Use the printable margin area (not the whole page) so the border can
        # hug the actual content instead of stretching to full page height.
        $mb  = $e.MarginBounds
        $left = $mb.Left; $right = $mb.Right; $pageBottomLimit = $mb.Bottom
        $tableWidth = $right - $left
        $topStart = $mb.Top

        $y = $topStart + 12

        # ---- Header (centered, bold) ----
        $g.DrawString("VANI, MEERUT", $fontHeader, $navyBrush, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, 28)), $centerFmt); $y += 30
        $g.DrawString("DASH X - Cricket Tennis Balls", $fontSub, $black, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, 18)), $centerFmt); $y += 20
        $billTypeTitle = "ROUGH ESTIMATE"
        if ("$($Bill.BillType)".Trim() -eq "Tax Invoice") { $billTypeTitle = "TAX INVOICE" }
        if ($printState.Index -gt 0) { $billTypeTitle = "$billTypeTitle (Continued)" }
        $g.DrawString($billTypeTitle, $fontSub, $navyBrush, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, 18)), $centerFmt); $y += 22
        $g.DrawLine($navyPen, $left, $y, $right, $y); $y += 15

        $custName = $Bill.CustomerText
        if ($Bill.CustomerText -match ' - ') { $custName = ($Bill.CustomerText -split ' - ', 2)[1] }
        $g.DrawString("Bill No: $($Bill.BillNo)", $fontNorm, $black, $left, $y)
        $g.DrawString("Date: $($Bill.BillDate)", $fontNorm, $black, ($left + 390), $y); $y += 22
        $g.DrawString("Customer: $custName", $fontNorm, $black, $left, $y); $y += 20
        $g.DrawString("Address: $($Bill.Address), $($Bill.City)", $fontNorm, $black, $left, $y); $y += 20
        $g.DrawString("Mobile: $($Bill.Mobile)", $fontNorm, $black, $left, $y); $y += 20

        # ---- Item table: column boundaries ----
        $colDescW = [Math]::Round($tableWidth * 0.52); $colQtyW = [Math]::Round($tableWidth * 0.10); $colRateW = [Math]::Round($tableWidth * 0.17)
        $cX0 = $left
        $cX1 = $cX0 + $colDescW
        $cX2 = $cX1 + $colQtyW
        $cX3 = $cX2 + $colRateW
        $cX4 = $right

        $headerRowH = 24
        $rowH = 20
        $totalsGap = 20; $boxW = 260; $boxH = 98; $footerGap = 30; $footerH = 18
        $reserveForTotals = $totalsGap + $boxH + $footerGap + $footerH + 10
        $continuedNoteH = 30

        $totalItems = $Bill.Items.Count
        $startIdx = $printState.Index
        $availForItems = $pageBottomLimit - $y - $headerRowH - $reserveForTotals
        $maxRows = [Math]::Max(1, [Math]::Floor($availForItems / $rowH))
        $remaining = $totalItems - $startIdx
        $isLastPage = ($remaining -le $maxRows)
        $rowsThisPage = if ($isLastPage) { $remaining } else { $maxRows }
        if ($rowsThisPage -lt 0) { $rowsThisPage = 0 }

        $tableTop = $y
        $tableBottom = $tableTop + $headerRowH + ($rowsThisPage * $rowH)

        # Shaded header row background
        $g.FillRectangle($headerFillBrush, $cX0, $tableTop, $tableWidth, $headerRowH)

        # Header labels
        $hdrY = New-Object System.Drawing.RectangleF($cX0, $tableTop, ($cX1 - $cX0 - 6), $headerRowH)
        $g.DrawString("Description", $fontSub, $black, $hdrY, $midFmt)
        $g.DrawString("Qty",    $fontSub, $black, (New-Object System.Drawing.RectangleF($cX1, $tableTop, ($cX2 - $cX1 - 6), $headerRowH)), $rightFmt)
        $g.DrawString("Rate",   $fontSub, $black, (New-Object System.Drawing.RectangleF($cX2, $tableTop, ($cX3 - $cX2 - 6), $headerRowH)), $rightFmt)
        $g.DrawString("Amount", $fontSub, $black, (New-Object System.Drawing.RectangleF($cX3, $tableTop, ($cX4 - $cX3 - 6), $headerRowH)), $rightFmt)

        # Item rows for this page only
        $ry = $tableTop + $headerRowH
        for ($i = 0; $i -lt $rowsThisPage; $i++) {
            $it = $Bill.Items[$startIdx + $i]
            $rowRect = New-Object System.Drawing.RectangleF($cX0, $ry, ($cX1 - $cX0 - 6), $rowH)
            $g.DrawString("$($it.Description)", $fontSmall, $black, $rowRect, $midFmt)
            $g.DrawString("$($it.Qty)",    $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX1, $ry, ($cX2 - $cX1 - 6), $rowH)), $rightFmt)
            $g.DrawString("$($it.Rate)",   $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX2, $ry, ($cX3 - $cX2 - 6), $rowH)), $rightFmt)
            $g.DrawString("$($it.Amount)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX3, $ry, ($cX4 - $cX3 - 6), $rowH)), $rightFmt)
            $ry += $rowH
            $g.DrawLine($grayPen, $cX0, $ry, $cX4, $ry)
        }

        # Table borders: outer box, header/body divider, and column gridlines
        $g.DrawRectangle($blackPen, $cX0, $tableTop, $tableWidth, ($tableBottom - $tableTop))
        $g.DrawLine($blackPen, $cX0, ($tableTop + $headerRowH), $cX4, ($tableTop + $headerRowH))
        foreach ($cx in @($cX1, $cX2, $cX3)) {
            $g.DrawLine($blackPen, $cx, $tableTop, $cx, $tableBottom)
        }

        $y = $tableBottom + $totalsGap
        $contentBottom = $tableBottom

        if ($isLastPage) {
            # ---- Totals box (bordered, right-aligned, bottom-right) ----
            $boxX = $right - $boxW
            $g.FillRectangle($totalsFillBrush, $boxX, $y, $boxW, $boxH)
            $g.DrawRectangle($blackPen, $boxX, $y, $boxW, $boxH)
            $labelW = 140; $valW = $boxW - $labelW - 20
            $ty = $y + 8

            $gstPctVal = 0.0; [double]::TryParse("$($Bill.GstPct)", [ref]$gstPctVal) | Out-Null
            $taxLabel = if ($gstPctVal -gt 0) { "Tax ($($Bill.GstPct)%):" } else { "Tax:" }

            $g.DrawString("Total:", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
            $g.DrawString("Rs. $($Bill.Total)", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt); $ty += 24

            $g.DrawString($taxLabel, $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
            $g.DrawString("Rs. $($Bill.GstAmt)", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt); $ty += 24
            $g.DrawLine($blackPen, ($boxX + 8), $ty, ($boxX + $boxW - 8), $ty); $ty += 6

            $g.DrawString("Net Amount:", $fontTotal, $navyBrush, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
            $g.DrawString("Rs. $($Bill.NetAmount)", $fontTotal, $navyBrush, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt)

            $y += $boxH + $footerGap
            $g.DrawString("Thank you for your business!", $fontNorm, $black, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, $footerH)), $centerFmt)
            $contentBottom = $y + $footerH

            $printState.Index = $totalItems
            $e.HasMorePages = $false
        } else {
            $g.DrawString("...continued on next page...", $fontSmall, $black, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, $continuedNoteH)), $centerFmt)
            $contentBottom = $y + $continuedNoteH

            $printState.Index = $startIdx + $rowsThisPage
            $e.HasMorePages = $true
        }

        # ---- Outer border: hugs just this page's actual content ----
        $borderPad = 15
        $g.DrawRectangle($navyPen, ($left - $borderPad), ($topStart - $borderPad), ($tableWidth + 2 * $borderPad), ($contentBottom - $topStart + 2 * $borderPad))
    }.GetNewClosure()
    $doc.add_PrintPage($handler)

    $preview = New-Object System.Windows.Forms.PrintPreviewDialog
    $preview.Document = $doc
    $preview.Width = 950; $preview.Height = 750
    $preview.StartPosition = "CenterScreen"
    $preview.ShowDialog() | Out-Null
}

# ============================================================================
#  PARTY LEDGER (KHATA) PRINT PREVIEW
#  Same visual style as the Rough Estimate print (border, centered header,
#  shaded/gridlined table, bordered totals box) - paginated for long ledgers.
# ============================================================================
function Show-LedgerPrintPreview {
    param($PartyCode, $PartyName, $Rows)
    $doc = New-Object System.Drawing.Printing.PrintDocument
    $printState = @{ Index = 0 }
    $doc.add_BeginPrint({ $printState.Index = 0 }.GetNewClosure())
    $handler = {
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $fontHeader = New-Object System.Drawing.Font("Arial", 18, [System.Drawing.FontStyle]::Bold)
        $fontSub    = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
        $fontNorm   = New-Object System.Drawing.Font("Arial", 10)
        $fontSmall  = New-Object System.Drawing.Font("Arial", 8.5)
        $fontTotal  = New-Object System.Drawing.Font("Arial", 11, [System.Drawing.FontStyle]::Bold)

        $black     = [System.Drawing.Brushes]::Black
        $navyColor = [System.Drawing.Color]::FromArgb(0, 0, 128)
        $navyBrush = New-Object System.Drawing.SolidBrush($navyColor)
        $navyPen   = New-Object System.Drawing.Pen($navyColor, 2)
        $blackPen  = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1.2)
        $grayPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::Gainsboro, 1)
        $headerFillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::LightGray)
        $totalsFillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 245, 250))

        $centerFmt = New-Object System.Drawing.StringFormat
        $centerFmt.Alignment = [System.Drawing.StringAlignment]::Center
        $rightFmt = New-Object System.Drawing.StringFormat
        $rightFmt.Alignment = [System.Drawing.StringAlignment]::Far
        $rightFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rightFmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $midFmt = New-Object System.Drawing.StringFormat
        $midFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $midFmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap

        $mb  = $e.MarginBounds
        $left = $mb.Left; $right = $mb.Right; $pageBottomLimit = $mb.Bottom
        $tableWidth = $right - $left
        $topStart = $mb.Top

        $y = $topStart + 12

        # ---- Header (centered, bold) ----
        $g.DrawString("VANI, MEERUT", $fontHeader, $navyBrush, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, 28)), $centerFmt); $y += 30
        $g.DrawString("DASH X - Cricket Tennis Balls", $fontSub, $black, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, 18)), $centerFmt); $y += 20
        $titleText = "PARTY LEDGER STATEMENT"
        if ($printState.Index -gt 0) { $titleText = "$titleText (Continued)" }
        $g.DrawString($titleText, $fontSub, $navyBrush, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, 18)), $centerFmt); $y += 22
        $g.DrawLine($navyPen, $left, $y, $right, $y); $y += 15

        $g.DrawString("Party: $PartyCode - $PartyName", $fontNorm, $black, $left, $y)
        $g.DrawString("Date: $(Get-Date -Format 'dd-MM-yyyy')", $fontNorm, $black, ($left + 390), $y); $y += 24

        # ---- Ledger table: column boundaries ----
        # Balance column widened (was clipping "Dr"/"Cr" suffix on big amounts) by
        # trimming Date/VouNo/Particulars/Debit/Credit a bit; Balance gets the rest.
        $colDateW  = [Math]::Round($tableWidth * 0.12)
        $colVouW   = [Math]::Round($tableWidth * 0.12)
        $colPartW  = [Math]::Round($tableWidth * 0.26)
        $colDebitW = [Math]::Round($tableWidth * 0.12)
        $colCreditW = [Math]::Round($tableWidth * 0.12)
        $cX0 = $left
        $cX1 = $cX0 + $colDateW
        $cX2 = $cX1 + $colVouW
        $cX3 = $cX2 + $colPartW
        $cX4 = $cX3 + $colDebitW
        $cX5 = $cX4 + $colCreditW
        $cX6 = $right

        $headerRowH = 22
        $rowH = 18
        $totalsGap = 20; $boxW = 300; $boxH = 98; $footerGap = 30; $footerH = 18
        $reserveForTotals = $totalsGap + $boxH + $footerGap + $footerH + 10
        $continuedNoteH = 30

        $totalRows = $Rows.Count
        $startIdx = $printState.Index
        $availForRows = $pageBottomLimit - $y - $headerRowH - $reserveForTotals
        $maxRows = [Math]::Max(1, [Math]::Floor($availForRows / $rowH))
        $remaining = $totalRows - $startIdx
        $isLastPage = ($remaining -le $maxRows)
        $rowsThisPage = if ($isLastPage) { $remaining } else { $maxRows }
        if ($rowsThisPage -lt 0) { $rowsThisPage = 0 }

        $tableTop = $y
        $tableBottom = $tableTop + $headerRowH + ($rowsThisPage * $rowH)

        # Shaded header row background
        $g.FillRectangle($headerFillBrush, $cX0, $tableTop, $tableWidth, $headerRowH)

        # Header labels
        $g.DrawString("Date",        $fontSub, $black, (New-Object System.Drawing.RectangleF($cX0, $tableTop, ($cX1 - $cX0 - 4), $headerRowH)), $midFmt)
        $g.DrawString("Vou.No",      $fontSub, $black, (New-Object System.Drawing.RectangleF($cX1, $tableTop, ($cX2 - $cX1 - 4), $headerRowH)), $midFmt)
        $g.DrawString("Particulars", $fontSub, $black, (New-Object System.Drawing.RectangleF($cX2, $tableTop, ($cX3 - $cX2 - 6), $headerRowH)), $midFmt)
        $g.DrawString("Debit",       $fontSub, $black, (New-Object System.Drawing.RectangleF($cX3, $tableTop, ($cX4 - $cX3 - 6), $headerRowH)), $rightFmt)
        $g.DrawString("Credit",      $fontSub, $black, (New-Object System.Drawing.RectangleF($cX4, $tableTop, ($cX5 - $cX4 - 6), $headerRowH)), $rightFmt)
        $g.DrawString("Balance",     $fontSub, $black, (New-Object System.Drawing.RectangleF($cX5, $tableTop, ($cX6 - $cX5 - 6), $headerRowH)), $rightFmt)

        # Ledger rows for this page only
        $ry = $tableTop + $headerRowH
        for ($i = 0; $i -lt $rowsThisPage; $i++) {
            $r = $Rows[$startIdx + $i]
            $g.DrawString("$($r.Date)",  $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX0, $ry, ($cX1 - $cX0 - 4), $rowH)), $midFmt)
            $g.DrawString("$($r.VouNo)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX1, $ry, ($cX2 - $cX1 - 4), $rowH)), $midFmt)
            $g.DrawString("$($r.Particulars)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX2, $ry, ($cX3 - $cX2 - 6), $rowH)), $midFmt)
            $g.DrawString("$($r.Debit)",   $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX3, $ry, ($cX4 - $cX3 - 6), $rowH)), $rightFmt)
            $g.DrawString("$($r.Credit)",  $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX4, $ry, ($cX5 - $cX4 - 6), $rowH)), $rightFmt)
            $g.DrawString("$($r.Balance)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX5, $ry, ($cX6 - $cX5 - 6), $rowH)), $rightFmt)
            $ry += $rowH
            $g.DrawLine($grayPen, $cX0, $ry, $cX6, $ry)
        }

        # Table borders: outer box, header/body divider, and column gridlines
        $g.DrawRectangle($blackPen, $cX0, $tableTop, $tableWidth, ($tableBottom - $tableTop))
        $g.DrawLine($blackPen, $cX0, ($tableTop + $headerRowH), $cX6, ($tableTop + $headerRowH))
        foreach ($cx in @($cX1, $cX2, $cX3, $cX4, $cX5)) {
            $g.DrawLine($blackPen, $cx, $tableTop, $cx, $tableBottom)
        }

        $y = $tableBottom + $totalsGap
        $contentBottom = $tableBottom

        if ($isLastPage) {
            # ---- Totals box (bordered, right-aligned, bottom-right) ----
            $totalDebit = 0.0; $totalCredit = 0.0
            foreach ($r in $Rows) {
                $dv = 0.0; if ([double]::TryParse("$($r.Debit)", [ref]$dv)) { $totalDebit += $dv }
                $cv = 0.0; if ([double]::TryParse("$($r.Credit)", [ref]$cv)) { $totalCredit += $cv }
            }
            $closingBal = if ($Rows.Count -gt 0) { $Rows[$Rows.Count - 1].Balance } else { "0.00" }

            $boxX = $right - $boxW
            $g.FillRectangle($totalsFillBrush, $boxX, $y, $boxW, $boxH)
            $g.DrawRectangle($blackPen, $boxX, $y, $boxW, $boxH)
            $labelW = 110; $valW = $boxW - $labelW - 20
            $ty = $y + 8

            $g.DrawString("Total Debit:", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
            $g.DrawString("Rs. $($totalDebit.ToString('N2'))", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt); $ty += 24

            $g.DrawString("Total Credit:", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
            $g.DrawString("Rs. $($totalCredit.ToString('N2'))", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt); $ty += 24
            $g.DrawLine($blackPen, ($boxX + 8), $ty, ($boxX + $boxW - 8), $ty); $ty += 6

            $g.DrawString("Closing Bal.:", $fontTotal, $navyBrush, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
            $g.DrawString("$closingBal", $fontTotal, $navyBrush, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt)

            $y += $boxH + $footerGap
            $g.DrawString("-- End of Statement --", $fontNorm, $black, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, $footerH)), $centerFmt)
            $contentBottom = $y + $footerH

            $printState.Index = $totalRows
            $e.HasMorePages = $false
        } else {
            $g.DrawString("...continued on next page...", $fontSmall, $black, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, $continuedNoteH)), $centerFmt)
            $contentBottom = $y + $continuedNoteH

            $printState.Index = $startIdx + $rowsThisPage
            $e.HasMorePages = $true
        }

        # ---- Outer border: hugs just this page's actual content ----
        $borderPad = 15
        $g.DrawRectangle($navyPen, ($left - $borderPad), ($topStart - $borderPad), ($tableWidth + 2 * $borderPad), ($contentBottom - $topStart + 2 * $borderPad))
    }.GetNewClosure()
    $doc.add_PrintPage($handler)

    $preview = New-Object System.Windows.Forms.PrintPreviewDialog
    $preview.Document = $doc
    $preview.Width = 950; $preview.Height = 750
    $preview.StartPosition = "CenterScreen"
    $preview.ShowDialog() | Out-Null
}

function Get-LedgerImage {
    # Party Ledger / Customer Statement ki EXACT wahi design jo print mein
    # dikhti hai, ek single lambi image ke roop mein - taaki WhatsApp par
    # asli statement bheja ja sake, sirf text summary nahi.
    param($PartyCode, $PartyName, $Rows, [string]$Title = "PARTY LEDGER STATEMENT")
    try {
        $left = 30; $topStart = 30; $tableWidth = 740; $right = $left + $tableWidth

        $fontHeader = New-Object System.Drawing.Font("Arial", 18, [System.Drawing.FontStyle]::Bold)
        $fontSub    = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
        $fontNorm   = New-Object System.Drawing.Font("Arial", 10)
        $fontSmall  = New-Object System.Drawing.Font("Arial", 8.5)
        $fontTotal  = New-Object System.Drawing.Font("Arial", 11, [System.Drawing.FontStyle]::Bold)

        $black     = [System.Drawing.Brushes]::Black
        $navyColor = [System.Drawing.Color]::FromArgb(0, 0, 128)
        $navyBrush = New-Object System.Drawing.SolidBrush($navyColor)
        $navyPen   = New-Object System.Drawing.Pen($navyColor, 2)
        $blackPen  = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1.2)
        $grayPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::Gainsboro, 1)
        $headerFillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::LightGray)
        $totalsFillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 245, 250))

        $centerFmt = New-Object System.Drawing.StringFormat
        $centerFmt.Alignment = [System.Drawing.StringAlignment]::Center
        $rightFmt = New-Object System.Drawing.StringFormat
        $rightFmt.Alignment = [System.Drawing.StringAlignment]::Far
        $rightFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rightFmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $midFmt = New-Object System.Drawing.StringFormat
        $midFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $midFmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap

        $rowsArr = @($Rows)
        $rowCount = $rowsArr.Count
        $headerRowH = 22; $rowH = 18
        $boxW = 300; $boxH = 98; $totalsGap = 20; $footerGap = 30; $footerH = 18

        $y = $topStart + 12
        $y += 30 + 20 + 22 + 15   # header block
        $y += 24                  # Party/Date line
        $tableTop = $y
        $tableBottom = $tableTop + $headerRowH + ($rowCount * $rowH)
        $boxY = $tableBottom + $totalsGap
        $footerY = $boxY + $boxH + $footerGap
        $contentBottom = $footerY + $footerH
        $borderPad = 15
        $imgW = [int]($right + $borderPad + 30)
        $imgH = [int]($contentBottom + $borderPad + 30)

        $bmp = New-Object System.Drawing.Bitmap($imgW, $imgH)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::White)

        $yy = $topStart + 12
        $g.DrawString("VANI, MEERUT", $fontHeader, $navyBrush, (New-Object System.Drawing.RectangleF($left, $yy, $tableWidth, 28)), $centerFmt); $yy += 30
        $g.DrawString("DASH X - Cricket Tennis Balls", $fontSub, $black, (New-Object System.Drawing.RectangleF($left, $yy, $tableWidth, 18)), $centerFmt); $yy += 20
        $g.DrawString($Title, $fontSub, $navyBrush, (New-Object System.Drawing.RectangleF($left, $yy, $tableWidth, 18)), $centerFmt); $yy += 22
        $g.DrawLine($navyPen, $left, $yy, $right, $yy); $yy += 15

        $g.DrawString("Party: $PartyCode - $PartyName", $fontNorm, $black, $left, $yy)
        $g.DrawString("Date: $(Get-Date -Format 'dd-MM-yyyy')", $fontNorm, $black, ($left + 390), $yy); $yy += 24

        $colDateW  = [Math]::Round($tableWidth * 0.12)
        $colVouW   = [Math]::Round($tableWidth * 0.12)
        $colPartW  = [Math]::Round($tableWidth * 0.26)
        $colDebitW = [Math]::Round($tableWidth * 0.12)
        $colCreditW = [Math]::Round($tableWidth * 0.12)
        $cX0 = $left
        $cX1 = $cX0 + $colDateW
        $cX2 = $cX1 + $colVouW
        $cX3 = $cX2 + $colPartW
        $cX4 = $cX3 + $colDebitW
        $cX5 = $cX4 + $colCreditW
        $cX6 = $right

        $g.FillRectangle($headerFillBrush, $cX0, $tableTop, $tableWidth, $headerRowH)
        $g.DrawString("Date",        $fontSub, $black, (New-Object System.Drawing.RectangleF($cX0, $tableTop, ($cX1 - $cX0 - 4), $headerRowH)), $midFmt)
        $g.DrawString("Vou.No",      $fontSub, $black, (New-Object System.Drawing.RectangleF($cX1, $tableTop, ($cX2 - $cX1 - 4), $headerRowH)), $midFmt)
        $g.DrawString("Particulars", $fontSub, $black, (New-Object System.Drawing.RectangleF($cX2, $tableTop, ($cX3 - $cX2 - 6), $headerRowH)), $midFmt)
        $g.DrawString("Debit",       $fontSub, $black, (New-Object System.Drawing.RectangleF($cX3, $tableTop, ($cX4 - $cX3 - 6), $headerRowH)), $rightFmt)
        $g.DrawString("Credit",      $fontSub, $black, (New-Object System.Drawing.RectangleF($cX4, $tableTop, ($cX5 - $cX4 - 6), $headerRowH)), $rightFmt)
        $g.DrawString("Balance",     $fontSub, $black, (New-Object System.Drawing.RectangleF($cX5, $tableTop, ($cX6 - $cX5 - 6), $headerRowH)), $rightFmt)

        $ry = $tableTop + $headerRowH
        foreach ($r in $rowsArr) {
            $g.DrawString("$($r.Date)",  $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX0, $ry, ($cX1 - $cX0 - 4), $rowH)), $midFmt)
            $g.DrawString("$($r.VouNo)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX1, $ry, ($cX2 - $cX1 - 4), $rowH)), $midFmt)
            $g.DrawString("$($r.Particulars)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX2, $ry, ($cX3 - $cX2 - 6), $rowH)), $midFmt)
            $g.DrawString("$($r.Debit)",   $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX3, $ry, ($cX4 - $cX3 - 6), $rowH)), $rightFmt)
            $g.DrawString("$($r.Credit)",  $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX4, $ry, ($cX5 - $cX4 - 6), $rowH)), $rightFmt)
            $g.DrawString("$($r.Balance)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX5, $ry, ($cX6 - $cX5 - 6), $rowH)), $rightFmt)
            $ry += $rowH
            $g.DrawLine($grayPen, $cX0, $ry, $cX6, $ry)
        }

        $g.DrawRectangle($blackPen, $cX0, $tableTop, $tableWidth, ($tableBottom - $tableTop))
        $g.DrawLine($blackPen, $cX0, ($tableTop + $headerRowH), $cX6, ($tableTop + $headerRowH))
        foreach ($cx in @($cX1, $cX2, $cX3, $cX4, $cX5)) { $g.DrawLine($blackPen, $cx, $tableTop, $cx, $tableBottom) }

        $totalDebit = 0.0; $totalCredit = 0.0
        foreach ($r in $rowsArr) {
            $dv = 0.0; if ([double]::TryParse("$($r.Debit)", [ref]$dv)) { $totalDebit += $dv }
            $cv = 0.0; if ([double]::TryParse("$($r.Credit)", [ref]$cv)) { $totalCredit += $cv }
        }
        $closingBal = if ($rowsArr.Count -gt 0) { $rowsArr[$rowsArr.Count - 1].Balance } else { "0.00" }

        $boxX = $right - $boxW
        $g.FillRectangle($totalsFillBrush, $boxX, $boxY, $boxW, $boxH)
        $g.DrawRectangle($blackPen, $boxX, $boxY, $boxW, $boxH)
        $labelW = 110; $valW = $boxW - $labelW - 20
        $ty = $boxY + 8

        $g.DrawString("Total Debit:", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
        $g.DrawString("Rs. $($totalDebit.ToString('N2'))", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt); $ty += 24

        $g.DrawString("Total Credit:", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
        $g.DrawString("Rs. $($totalCredit.ToString('N2'))", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt); $ty += 24
        $g.DrawLine($blackPen, ($boxX + 8), $ty, ($boxX + $boxW - 8), $ty); $ty += 6

        $g.DrawString("Closing Bal.:", $fontTotal, $navyBrush, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
        $g.DrawString("$closingBal", $fontTotal, $navyBrush, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt)

        $g.DrawString("-- End of Statement --", $fontNorm, $black, (New-Object System.Drawing.RectangleF($left, $footerY, $tableWidth, $footerH)), $centerFmt)

        $g.DrawRectangle($navyPen, ($left - $borderPad), ($topStart - $borderPad), ($tableWidth + 2 * $borderPad), ($contentBottom - $topStart + 2 * $borderPad))

        if (-not (Test-Path $WhatsAppBillsFolder)) { New-Item -ItemType Directory -Path $WhatsAppBillsFolder | Out-Null }
        $safeCode = "$PartyCode" -replace '[^A-Za-z0-9_-]', '_'
        $stamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $path = Join-Path $WhatsAppBillsFolder "Statement_$($safeCode)_$stamp.png"
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        return $path
    } catch {
        return $null
    }
}

# ============================================================================
#  ROUGH ESTIMATE REGISTER PRINT PREVIEW
#  Prints the full list of Rough Estimate bills as one register (Sr.No, Bill
#  No, Date, Customer, City, Amount) with a grand-total box - same visual
#  style as the other prints, paginated for a long list.
# ============================================================================
function Show-RegisterPrintPreview {
    param($Bills)
    $doc = New-Object System.Drawing.Printing.PrintDocument
    $printState = @{ Index = 0 }
    $doc.add_BeginPrint({ $printState.Index = 0 }.GetNewClosure())
    $handler = {
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

        $fontHeader = New-Object System.Drawing.Font("Arial", 18, [System.Drawing.FontStyle]::Bold)
        $fontSub    = New-Object System.Drawing.Font("Arial", 10, [System.Drawing.FontStyle]::Bold)
        $fontNorm   = New-Object System.Drawing.Font("Arial", 10)
        $fontSmall  = New-Object System.Drawing.Font("Arial", 8.5)
        $fontTotal  = New-Object System.Drawing.Font("Arial", 11, [System.Drawing.FontStyle]::Bold)

        $black     = [System.Drawing.Brushes]::Black
        $navyColor = [System.Drawing.Color]::FromArgb(0, 0, 128)
        $navyBrush = New-Object System.Drawing.SolidBrush($navyColor)
        $navyPen   = New-Object System.Drawing.Pen($navyColor, 2)
        $blackPen  = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1.2)
        $grayPen   = New-Object System.Drawing.Pen([System.Drawing.Color]::Gainsboro, 1)
        $headerFillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::LightGray)
        $totalsFillBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 245, 250))

        $centerFmt = New-Object System.Drawing.StringFormat
        $centerFmt.Alignment = [System.Drawing.StringAlignment]::Center
        $rightFmt = New-Object System.Drawing.StringFormat
        $rightFmt.Alignment = [System.Drawing.StringAlignment]::Far
        $rightFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $rightFmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
        $midFmt = New-Object System.Drawing.StringFormat
        $midFmt.LineAlignment = [System.Drawing.StringAlignment]::Center
        $midFmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap

        $mb  = $e.MarginBounds
        $left = $mb.Left; $right = $mb.Right; $pageBottomLimit = $mb.Bottom
        $tableWidth = $right - $left
        $topStart = $mb.Top

        $y = $topStart + 12

        # ---- Header (centered, bold) ----
        $g.DrawString("VANI, MEERUT", $fontHeader, $navyBrush, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, 28)), $centerFmt); $y += 30
        $g.DrawString("DASH X - Cricket Tennis Balls", $fontSub, $black, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, 18)), $centerFmt); $y += 20
        $titleText = "ROUGH ESTIMATE REGISTER"
        if ($printState.Index -gt 0) { $titleText = "$titleText (Continued)" }
        $g.DrawString($titleText, $fontSub, $navyBrush, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, 18)), $centerFmt); $y += 22
        $g.DrawLine($navyPen, $left, $y, $right, $y); $y += 15

        $g.DrawString("As on: $(Get-Date -Format 'dd-MM-yyyy')", $fontNorm, $black, $left, $y)
        $g.DrawString("Total Bills: $($Bills.Count)", $fontNorm, $black, ($left + 390), $y); $y += 24

        # ---- Register table: column boundaries ----
        $colSrW   = [Math]::Round($tableWidth * 0.08)
        $colNoW   = [Math]::Round($tableWidth * 0.13)
        $colDateW = [Math]::Round($tableWidth * 0.14)
        $colCustW = [Math]::Round($tableWidth * 0.36)
        $colCityW = [Math]::Round($tableWidth * 0.14)
        $cX0 = $left
        $cX1 = $cX0 + $colSrW
        $cX2 = $cX1 + $colNoW
        $cX3 = $cX2 + $colDateW
        $cX4 = $cX3 + $colCustW
        $cX5 = $cX4 + $colCityW
        $cX6 = $right

        $headerRowH = 22
        $rowH = 18
        $totalsGap = 20; $boxW = 260; $boxH = 60; $footerGap = 30; $footerH = 18
        $reserveForTotals = $totalsGap + $boxH + $footerGap + $footerH + 10
        $continuedNoteH = 30

        $totalRows = $Bills.Count
        $startIdx = $printState.Index
        $availForRows = $pageBottomLimit - $y - $headerRowH - $reserveForTotals
        $maxRows = [Math]::Max(1, [Math]::Floor($availForRows / $rowH))
        $remaining = $totalRows - $startIdx
        $isLastPage = ($remaining -le $maxRows)
        $rowsThisPage = if ($isLastPage) { $remaining } else { $maxRows }
        if ($rowsThisPage -lt 0) { $rowsThisPage = 0 }

        $tableTop = $y
        $tableBottom = $tableTop + $headerRowH + ($rowsThisPage * $rowH)

        # Shaded header row background
        $g.FillRectangle($headerFillBrush, $cX0, $tableTop, $tableWidth, $headerRowH)

        # Header labels
        $g.DrawString("Sr.No",    $fontSub, $black, (New-Object System.Drawing.RectangleF($cX0, $tableTop, ($cX1 - $cX0 - 4), $headerRowH)), $midFmt)
        $g.DrawString("Bill No",  $fontSub, $black, (New-Object System.Drawing.RectangleF($cX1, $tableTop, ($cX2 - $cX1 - 4), $headerRowH)), $midFmt)
        $g.DrawString("Date",     $fontSub, $black, (New-Object System.Drawing.RectangleF($cX2, $tableTop, ($cX3 - $cX2 - 4), $headerRowH)), $midFmt)
        $g.DrawString("Customer", $fontSub, $black, (New-Object System.Drawing.RectangleF($cX3, $tableTop, ($cX4 - $cX3 - 6), $headerRowH)), $midFmt)
        $g.DrawString("City",     $fontSub, $black, (New-Object System.Drawing.RectangleF($cX4, $tableTop, ($cX5 - $cX4 - 6), $headerRowH)), $midFmt)
        $g.DrawString("Amount",   $fontSub, $black, (New-Object System.Drawing.RectangleF($cX5, $tableTop, ($cX6 - $cX5 - 6), $headerRowH)), $rightFmt)

        # Register rows for this page only
        $ry = $tableTop + $headerRowH
        for ($i = 0; $i -lt $rowsThisPage; $i++) {
            $b = $Bills[$startIdx + $i]
            $custName = "$($b.CustomerText)"
            if ($custName -match ' - ') { $custName = ($custName -split ' - ', 2)[1] }
            $g.DrawString("$($startIdx + $i + 1)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX0, $ry, ($cX1 - $cX0 - 4), $rowH)), $midFmt)
            $g.DrawString("$($b.BillNo)",  $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX1, $ry, ($cX2 - $cX1 - 4), $rowH)), $midFmt)
            $g.DrawString("$($b.BillDate)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX2, $ry, ($cX3 - $cX2 - 4), $rowH)), $midFmt)
            $g.DrawString("$custName",     $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX3, $ry, ($cX4 - $cX3 - 6), $rowH)), $midFmt)
            $g.DrawString("$($b.City)",    $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX4, $ry, ($cX5 - $cX4 - 6), $rowH)), $midFmt)
            $g.DrawString("$($b.NetAmount)", $fontSmall, $black, (New-Object System.Drawing.RectangleF($cX5, $ry, ($cX6 - $cX5 - 6), $rowH)), $rightFmt)
            $ry += $rowH
            $g.DrawLine($grayPen, $cX0, $ry, $cX6, $ry)
        }

        # Table borders: outer box, header/body divider, and column gridlines
        $g.DrawRectangle($blackPen, $cX0, $tableTop, $tableWidth, ($tableBottom - $tableTop))
        $g.DrawLine($blackPen, $cX0, ($tableTop + $headerRowH), $cX6, ($tableTop + $headerRowH))
        foreach ($cx in @($cX1, $cX2, $cX3, $cX4, $cX5)) {
            $g.DrawLine($blackPen, $cx, $tableTop, $cx, $tableBottom)
        }

        $y = $tableBottom + $totalsGap
        $contentBottom = $tableBottom

        if ($isLastPage) {
            # ---- Grand total box (bordered, right-aligned, bottom-right) ----
            $grandTotal = 0.0
            foreach ($b in $Bills) {
                $v = 0.0
                [double]::TryParse(("$($b.NetAmount)" -replace ',', ''), [ref]$v) | Out-Null
                $grandTotal += $v
            }

            $boxX = $right - $boxW
            $g.FillRectangle($totalsFillBrush, $boxX, $y, $boxW, $boxH)
            $g.DrawRectangle($blackPen, $boxX, $y, $boxW, $boxH)
            $labelW = 130; $valW = $boxW - $labelW - 20
            $ty = $y + 8

            $g.DrawString("Total Bills:", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
            $g.DrawString("$($Bills.Count)", $fontNorm, $black, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt); $ty += 24
            $g.DrawLine($blackPen, ($boxX + 8), $ty, ($boxX + $boxW - 8), $ty); $ty += 6

            $g.DrawString("Grand Total:", $fontTotal, $navyBrush, (New-Object System.Drawing.RectangleF(($boxX + 10), $ty, $labelW, 22)), $midFmt)
            $g.DrawString("Rs. $($grandTotal.ToString('N2'))", $fontTotal, $navyBrush, (New-Object System.Drawing.RectangleF(($boxX + 10 + $labelW), $ty, $valW, 22)), $rightFmt)

            $y += $boxH + $footerGap
            $g.DrawString("-- End of Register --", $fontNorm, $black, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, $footerH)), $centerFmt)
            $contentBottom = $y + $footerH

            $printState.Index = $totalRows
            $e.HasMorePages = $false
        } else {
            $g.DrawString("...continued on next page...", $fontSmall, $black, (New-Object System.Drawing.RectangleF($left, $y, $tableWidth, $continuedNoteH)), $centerFmt)
            $contentBottom = $y + $continuedNoteH

            $printState.Index = $startIdx + $rowsThisPage
            $e.HasMorePages = $true
        }

        # ---- Outer border: hugs just this page's actual content ----
        $borderPad = 15
        $g.DrawRectangle($navyPen, ($left - $borderPad), ($topStart - $borderPad), ($tableWidth + 2 * $borderPad), ($contentBottom - $topStart + 2 * $borderPad))
    }.GetNewClosure()
    $doc.add_PrintPage($handler)

    $preview = New-Object System.Windows.Forms.PrintPreviewDialog
    $preview.Document = $doc
    $preview.Width = 950; $preview.Height = 750
    $preview.StartPosition = "CenterScreen"
    $preview.ShowDialog() | Out-Null
}

# ============================================================================
#  QUICK PRODUCT PICKER - jab "Item Code / Naam" box mein type kiya hua text
#  se ek se zyada product match ho, tab yeh chhota list dialog dikhta hai.
# ============================================================================
function Show-ProductPickerDialog {
    param($Matches)
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Item Select Karein"; $dlg.Size = New-Object System.Drawing.Size(420, 420)
    $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = $FontNormal
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "$($Matches.Count) item mile - jo chahiye usko double-click karein (ya select karke OK):"
    $lbl.Location = New-Object System.Drawing.Point(10, 10); $lbl.Size = New-Object System.Drawing.Size(390, 36)
    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location = New-Object System.Drawing.Point(10, 50); $lst.Size = New-Object System.Drawing.Size(385, 280)
    $lst.Font = $FontNormal
    foreach ($p in $Matches) { [void]$lst.Items.Add("$($p.Code) - $($p.Desc) (Rs.$($p.Rate))") }
    if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = 0 }
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"; $btnOk.Font = $FontBold; $btnOk.Location = New-Object System.Drawing.Point(100, 340); $btnOk.Size = New-Object System.Drawing.Size(100, 32)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"; $btnCancel.Location = New-Object System.Drawing.Point(210, 340); $btnCancel.Size = New-Object System.Drawing.Size(100, 32)
    $dlg.Controls.Add($lbl); $dlg.Controls.Add($lst); $dlg.Controls.Add($btnOk); $dlg.Controls.Add($btnCancel)
    $dlg.AcceptButton = $btnOk
    $btnOk.Add_Click({ $dlg.Tag = $lst.SelectedIndex; $dlg.Close() })
    $btnCancel.Add_Click({ $dlg.Tag = -1; $dlg.Close() })
    $lst.Add_DoubleClick({ $dlg.Tag = $lst.SelectedIndex; $dlg.Close() })
    $dlg.ShowDialog() | Out-Null
    $idx = $dlg.Tag
    if ($null -eq $idx -or $idx -lt 0) { return $null }
    return $Matches[$idx]
}

# ============================================================================
#  ITEM FINDER (F8) - a dedicated fast lookup popup, separate from the
#  Barcode/Item Code/Naam box's own live dropdown. Type any part of a
#  product's code or name, the list below updates live, Enter/double-click
#  picks it. Returns the selected product object, or $null if cancelled.
#  Added 2026-09-09 (session 12).
# ============================================================================
function Show-ItemFinderDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Find Item"
    $dlg.Size = New-Object System.Drawing.Size(460, 460)
    $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = $FontNormal
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = "Item ka naam ya code type karein (list neeche live update hogi):"
    $lbl.Location = New-Object System.Drawing.Point(10, 10); $lbl.Size = New-Object System.Drawing.Size(420, 20)
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(10, 34); $txt.Size = New-Object System.Drawing.Size(420, 24); $txt.Font = $FontNormal
    $lst = New-Object System.Windows.Forms.ListBox
    $lst.Location = New-Object System.Drawing.Point(10, 66); $lst.Size = New-Object System.Drawing.Size(420, 300); $lst.Font = $FontNormal
    $dlg.Controls.Add($lbl) | Out-Null
    $dlg.Controls.Add($txt) | Out-Null
    $dlg.Controls.Add($lst) | Out-Null

    $script:ItemFinderFiltered = @($script:AllProducts)
    function Refresh-ItemFinderList {
        $t = $txt.Text.Trim()
        $script:ItemFinderFiltered = if ($t.Length -ge 1) {
            @($script:AllProducts | Where-Object { "$($_.Desc)" -like "*$t*" -or "$($_.Code)" -like "*$t*" } | Select-Object -First 100)
        } else {
            @($script:AllProducts | Select-Object -First 100)
        }
        $lst.Items.Clear()
        foreach ($p in $script:ItemFinderFiltered) { [void]$lst.Items.Add("$($p.Code) - $($p.Desc) (Rs.$($p.Rate))") }
        if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = 0 }
    }
    Refresh-ItemFinderList
    $txt.Add_TextChanged({ Refresh-ItemFinderList })
    $txt.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Down') {
            if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = [Math]::Min($lst.SelectedIndex + 1, $lst.Items.Count - 1) }
            $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Up') {
            if ($lst.Items.Count -gt 0) { $lst.SelectedIndex = [Math]::Max($lst.SelectedIndex - 1, 0) }
            $e.Handled = $true; $e.SuppressKeyPress = $true
        } elseif ($e.KeyCode -eq 'Return') {
            if ($lst.SelectedIndex -ge 0) { $dlg.Tag = $lst.SelectedIndex; $dlg.Close() }
            $e.Handled = $true; $e.SuppressKeyPress = $true
        }
    })
    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "Select"; $btnOk.Font = $FontBold; $btnOk.Location = New-Object System.Drawing.Point(120, 376); $btnOk.Size = New-Object System.Drawing.Size(100, 32)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"; $btnCancel.Location = New-Object System.Drawing.Point(230, 376); $btnCancel.Size = New-Object System.Drawing.Size(100, 32)
    $dlg.Controls.Add($btnOk) | Out-Null
    $dlg.Controls.Add($btnCancel) | Out-Null
    $btnOk.Add_Click({ $dlg.Tag = $lst.SelectedIndex; $dlg.Close() })
    $btnCancel.Add_Click({ $dlg.Tag = -1; $dlg.Close() })
    $lst.Add_DoubleClick({ $dlg.Tag = $lst.SelectedIndex; $dlg.Close() })
    $dlg.Add_Shown({ $txt.Focus() })
    $dlg.ShowDialog() | Out-Null
    $idx = $dlg.Tag
    if ($null -eq $idx -or $idx -lt 0 -or $idx -ge $script:ItemFinderFiltered.Count) { return $null }
    return $script:ItemFinderFiltered[$idx]
}

# ============================================================================
#  SALES BILL ENTRY FORM
# ============================================================================
function Show-SalesBillForm {
    param($Existing = $null)
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Sales Bill Entry"
    $form.Size = New-Object System.Drawing.Size(960, 710)
    $form.MinimumSize = New-Object System.Drawing.Size(960, 710)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"
    $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control
    $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "SALES BILL ENTRY" 944))

    $grpBill = New-Object System.Windows.Forms.GroupBox
    $grpBill.Text = "Bill Details"; $grpBill.Font = $FontBold
    $grpBill.Location = New-Object System.Drawing.Point(12, 50); $grpBill.Size = New-Object System.Drawing.Size(910, 60)
    $lblBillNo = New-Object System.Windows.Forms.Label
    $lblBillNo.Text = "Bill No:"; $lblBillNo.Location = New-Object System.Drawing.Point(15, 25); $lblBillNo.AutoSize = $true
    $txtBillNo = New-Object System.Windows.Forms.TextBox
    $txtBillNo.Location = New-Object System.Drawing.Point(75, 22); $txtBillNo.Size = New-Object System.Drawing.Size(90, 22)
    $txtBillNo.ReadOnly = $true; $txtBillNo.BackColor = [System.Drawing.Color]::LightYellow; $txtBillNo.Font = $FontBold
    $lblBillDate = New-Object System.Windows.Forms.Label
    $lblBillDate.Text = "Bill Date:"; $lblBillDate.Location = New-Object System.Drawing.Point(190, 25); $lblBillDate.AutoSize = $true
    $dtpBillDate = New-Object System.Windows.Forms.DateTimePicker
    $dtpBillDate.Format = "Short"; $dtpBillDate.Location = New-Object System.Drawing.Point(255, 22); $dtpBillDate.Size = New-Object System.Drawing.Size(110, 22)
    # 2026-09-09 (session 12): quick "Find Bill" lookup - opens the Rough
    # Estimate List (now with its own search box, see Show-BillListForm) so an
    # old bill can be found/opened in seconds without leaving this screen.
    $btnFindBill = New-Object System.Windows.Forms.Button
    $btnFindBill.Text = "Find Bill (F9)"; $btnFindBill.Font = $FontBold
    $btnFindBill.Location = New-Object System.Drawing.Point(780, 20); $btnFindBill.Size = New-Object System.Drawing.Size(120, 26)
    $btnFindBill.BackColor = [System.Drawing.Color]::FromArgb(225, 225, 245)
    $grpBill.Controls.Add($lblBillNo) | Out-Null
    $grpBill.Controls.Add($txtBillNo) | Out-Null
    $grpBill.Controls.Add($lblBillDate) | Out-Null
    $grpBill.Controls.Add($dtpBillDate) | Out-Null
    $grpBill.Controls.Add($btnFindBill) | Out-Null
    $btnFindBill.Add_Click({ Invoke-Safe { Show-BillListForm } })
    $form.Controls.Add($grpBill)

    $grpCust = New-Object System.Windows.Forms.GroupBox
    $grpCust.Text = "Customer Details"; $grpCust.Font = $FontBold
    $grpCust.Location = New-Object System.Drawing.Point(12, 115); $grpCust.Size = New-Object System.Drawing.Size(910, 116)
    $lblCust = New-Object System.Windows.Forms.Label
    $lblCust.Text = "Customer:"; $lblCust.Location = New-Object System.Drawing.Point(15, 28); $lblCust.AutoSize = $true
    $cboCustomer = New-Object System.Windows.Forms.ComboBox
    $cboCustomer.Location = New-Object System.Drawing.Point(100, 25); $cboCustomer.Size = New-Object System.Drawing.Size(360, 22)
    $cboCustomer.DropDownStyle = "DropDown"; $cboCustomer.AutoCompleteMode = "SuggestAppend"; $cboCustomer.AutoCompleteSource = "ListItems"
    $script:AllCustomers = Get-AllCustomers
    $script:AllProducts = Get-AllProducts
    $custList = New-Object System.Collections.ArrayList
    foreach ($c in $script:AllCustomers) { [void]$custList.Add("$($c.Code) - $($c.Name)") }
    $cboCustomer.Items.AddRange($custList.ToArray())
    Enable-ComboBoxContainsSearch -Combo $cboCustomer -GetAllItems { $custList.ToArray() }
    $lblCity = New-Object System.Windows.Forms.Label
    $lblCity.Text = "City:"; $lblCity.Location = New-Object System.Drawing.Point(475, 28); $lblCity.AutoSize = $true
    $txtCity = New-Object System.Windows.Forms.TextBox
    $txtCity.Location = New-Object System.Drawing.Point(515, 25); $txtCity.Size = New-Object System.Drawing.Size(180, 22); $txtCity.ReadOnly = $true
    $lblMobile = New-Object System.Windows.Forms.Label
    $lblMobile.Text = "Mobile:"; $lblMobile.Location = New-Object System.Drawing.Point(710, 28); $lblMobile.AutoSize = $true
    $txtMobile = New-Object System.Windows.Forms.TextBox
    $txtMobile.Location = New-Object System.Drawing.Point(765, 25); $txtMobile.Size = New-Object System.Drawing.Size(130, 22)
    $lblAddress = New-Object System.Windows.Forms.Label
    $lblAddress.Text = "Address:"; $lblAddress.Location = New-Object System.Drawing.Point(15, 58); $lblAddress.AutoSize = $true
    $txtAddress = New-Object System.Windows.Forms.TextBox
    $txtAddress.Location = New-Object System.Drawing.Point(100, 55); $txtAddress.Size = New-Object System.Drawing.Size(795, 22); $txtAddress.ReadOnly = $true
    $lblBalTitle = New-Object System.Windows.Forms.Label
    $lblBalTitle.Text = "Balance:"; $lblBalTitle.Location = New-Object System.Drawing.Point(15, 88); $lblBalTitle.AutoSize = $true
    $lblCustBalance = New-Object System.Windows.Forms.Label
    $lblCustBalance.Text = "-"; $lblCustBalance.Font = $FontBold; $lblCustBalance.ForeColor = $ColorVfpBlue
    $lblCustBalance.Location = New-Object System.Drawing.Point(100, 88); $lblCustBalance.AutoSize = $true
    $lblSearchHint = New-Object System.Windows.Forms.Label
    $lblSearchHint.Text = "(Naam ya Mobile number type karke bhi search kar sakte hain)"
    $lblSearchHint.Font = New-Object System.Drawing.Font("Tahoma", 8, [System.Drawing.FontStyle]::Italic)
    $lblSearchHint.ForeColor = [System.Drawing.Color]::DimGray
    $lblSearchHint.Location = New-Object System.Drawing.Point(300, 90); $lblSearchHint.AutoSize = $true
    $grpCust.Controls.Add($lblCust) | Out-Null
    $grpCust.Controls.Add($cboCustomer) | Out-Null
    $grpCust.Controls.Add($lblCity) | Out-Null
    $grpCust.Controls.Add($txtCity) | Out-Null
    $grpCust.Controls.Add($lblMobile) | Out-Null
    $grpCust.Controls.Add($txtMobile) | Out-Null
    $grpCust.Controls.Add($lblAddress) | Out-Null
    $grpCust.Controls.Add($txtAddress) | Out-Null
    $grpCust.Controls.Add($lblBalTitle) | Out-Null
    $grpCust.Controls.Add($lblCustBalance) | Out-Null
    $grpCust.Controls.Add($lblSearchHint) | Out-Null
    $form.Controls.Add($grpCust)

    function Update-CustomerDetails {
        if ($cboCustomer.Text.Trim() -eq "") { $lblCustBalance.Text = "-"; return }
        $typed = $cboCustomer.Text.Trim()
        $code = ($typed -split ' - ')[0].Trim()
        $c = $script:AllCustomers | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
        if (-not $c) {
            # User ne poora ya aadha naam type kiya hai (list se pick nahi kiya) -
            # ab naam ka koi bhi hissa match karega, exact poora naam type karne
            # ki zaroorat nahi (pehle sirf 100% exact naam hi chalta tha).
            # Sirf jab EXACTLY ek hi customer naam se match kare tabhi apne aap
            # fill karo - agar ek se zyada milte hain to safe rehne ke liye kuch
            # nahi karte (galat customer par bill nahi banna chahiye), Vineet ko
            # dropdown se sahi wala khud chunna hoga.
            $nameMatches = @($script:AllCustomers | Where-Object { "$($_.Name)" -like "*$typed*" })
            if ($nameMatches.Count -eq 1) {
                $c = $nameMatches[0]
                $cboCustomer.Text = "$($c.Code) - $($c.Name)"
            }
        }
        if (-not $c -and $typed -match '^\d{7,}$') {
            # smart search: typed a mobile number - match on that instead
            $c = $script:AllCustomers | Where-Object { "$($_.Mobile)".Trim() -match [regex]::Escape($typed) } | Select-Object -First 1
            if ($c) { $cboCustomer.Text = "$($c.Code) - $($c.Name)" }
        }
        if ($c) {
            $txtCity.Text = $c.City; $txtMobile.Text = $c.Mobile
            $txtAddress.Text = ("$($c.Add1) $($c.Add2)").Trim()
            $ledgerRows = Get-CustomerLedger -CustCode $c.Code
            if ($ledgerRows.Count -gt 0) {
                $lblCustBalance.Text = "Rs. $($ledgerRows[$ledgerRows.Count - 1].Balance)"
            } else {
                $lblCustBalance.Text = "Rs. 0.00"
            }
        } else {
            $lblCustBalance.Text = "-"
        }
    }
    $cboCustomer.Add_SelectedIndexChanged({ Update-CustomerDetails })
    $cboCustomer.Add_Leave({ Update-CustomerDetails })
    $cboCustomer.Add_TextChanged({
        # instant auto-fill once a full mobile number is typed (smart search)
        if ($cboCustomer.Text.Trim() -match '^\d{10}$') { Update-CustomerDetails }
    })

    $grpItems = New-Object System.Windows.Forms.GroupBox
    $grpItems.Text = "Items"; $grpItems.Font = $FontBold
    $grpItems.Location = New-Object System.Drawing.Point(12, 236); $grpItems.Size = New-Object System.Drawing.Size(910, 279)
    $grpItems.Anchor = "Top, Bottom, Left, Right"

    # 2026-09-09: the "Barcode / Item Code / Naam" quick-add box is back, but
    # is now an editable ComboBox (was a plain TextBox before) wired to the
    # same live "contains" search as the Customer box (Enable-ComboBoxContains-
    # Search) - so it now ALSO shows a filtered dropdown as you type, instead
    # of only working on Enter. Enter still works too (barcode scanners keep
    # working exactly as before - scan types the code then sends Enter).
    $lblBarcode = New-Object System.Windows.Forms.Label
    $lblBarcode.Text = "Barcode / Item Code / Naam:"; $lblBarcode.Font = $FontBold
    $lblBarcode.Location = New-Object System.Drawing.Point(10, 24); $lblBarcode.AutoSize = $true
    $cboBarcode = New-Object System.Windows.Forms.ComboBox
    $cboBarcode.Location = New-Object System.Drawing.Point(200, 21); $cboBarcode.Size = New-Object System.Drawing.Size(200, 22)
    $cboBarcode.DropDownStyle = "DropDown"
    $barcodeItems = New-Object System.Collections.Generic.List[string]
    foreach ($p in $script:AllProducts) { [void]$barcodeItems.Add("$($p.Code) - $($p.Desc)") }
    Enable-ComboBoxContainsSearch -Combo $cboBarcode -GetAllItems { $barcodeItems.ToArray() }
    # 2026-09-09 (session 12): "Find Item" popup (F8) - a bigger dedicated
    # search window (Show-ItemFinderDialog) alongside this box's own small
    # live dropdown, for when scrolling/typing here isn't enough.
    $btnFindItem = New-Object System.Windows.Forms.Button
    $btnFindItem.Text = "Find Item (F8)"; $btnFindItem.Font = $FontBold
    $btnFindItem.Location = New-Object System.Drawing.Point(410, 20); $btnFindItem.Size = New-Object System.Drawing.Size(130, 24)
    $btnFindItem.BackColor = [System.Drawing.Color]::FromArgb(225, 225, 245)
    $lblBarcodeHint = New-Object System.Windows.Forms.Label
    $lblBarcodeHint.Text = "(Scan karein, ya naam/code ka koi bhi hissa type karein - list mein se chunein ya Enter dabayein)"
    $lblBarcodeHint.Font = New-Object System.Drawing.Font("Tahoma", 8, [System.Drawing.FontStyle]::Italic)
    $lblBarcodeHint.ForeColor = [System.Drawing.Color]::DimGray
    $lblBarcodeHint.Location = New-Object System.Drawing.Point(10, 48); $lblBarcodeHint.AutoSize = $true
    $grpItems.Controls.Add($lblBarcode) | Out-Null
    $grpItems.Controls.Add($cboBarcode) | Out-Null
    $grpItems.Controls.Add($btnFindItem) | Out-Null
    $grpItems.Controls.Add($lblBarcodeHint) | Out-Null
    $btnFindItem.Add_Click({
        $p = Show-ItemFinderDialog
        if ($p) { Add-ProductRowToGrid $p }
        $cboBarcode.Focus()
    })

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(10, 76); $grid.Size = New-Object System.Drawing.Size(890, 193)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.ReadOnly = $false
    $grid.AllowUserToAddRows = $true; $grid.AllowUserToDeleteRows = $true
    $colCode = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    $colCode.Name = "Code"; $colCode.HeaderText = "Item (select from list)"; $colCode.Width = 300
    $colCode.FlatStyle = "Standard"
    $colCode.DisplayStyle = "ComboBox"
    $productItems = New-Object System.Collections.Generic.List[string]
    foreach ($p in $script:AllProducts) { [void]$productItems.Add("$($p.Code) - $($p.Desc)") }
    [void]$colCode.Items.AddRange([string[]]$productItems.ToArray())
    $colDesc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDesc.Name = "Description"; $colDesc.HeaderText = "Description"; $colDesc.Width = 220
    $colQty = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colQty.Name = "Qty"; $colQty.HeaderText = "Qty"; $colQty.Width = 70
    $colRate = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colRate.Name = "Rate"; $colRate.HeaderText = "Rate"; $colRate.Width = 90
    $colAmt = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colAmt.Name = "Amount"; $colAmt.HeaderText = "Amount"; $colAmt.Width = 100
    $colAmt.ReadOnly = $true; $colAmt.DefaultCellStyle.BackColor = $ColorGrid
    $grid.Columns.Add($colCode) | Out-Null
    $grid.Columns.Add($colDesc) | Out-Null
    $grid.Columns.Add($colQty) | Out-Null
    $grid.Columns.Add($colRate) | Out-Null
    $grid.Columns.Add($colAmt) | Out-Null
    $grpItems.Controls.Add($grid)
    $form.Controls.Add($grpItems)

    # single click on the Item column should immediately open the item list.
    # BeginInvoke defers opening the dropdown to right after the click finishes
    # processing - doing it immediately/synchronously is too early because the
    # editing ComboBox control has not finished being created yet.
    $grid.Add_CellClick({
        param($s, $e)
        if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 0) {
            # Guard against a fast double-click: CellClick fires once per click,
            # so a double-click calls this twice in quick succession. Calling
            # BeginEdit()/opening the dropdown a second time while the ComboBox
            # editing control is still being created can throw, and an
            # unhandled exception here freezes the whole app's message loop
            # (this was the "double-click/double-tap breaks everything" bug).
            # Skip if we're already editing this exact cell, and swallow any
            # error instead of letting it crash the UI thread.
            $already = $grid.IsCurrentCellInEditMode -and $grid.CurrentCell -and $grid.CurrentCell.RowIndex -eq $e.RowIndex -and $grid.CurrentCell.ColumnIndex -eq $e.ColumnIndex
            if ($already) { return }
            try {
                $grid.CurrentCell = $grid.Rows[$e.RowIndex].Cells[$e.ColumnIndex]
                $grid.BeginEdit($true)
                $openAction = [Action]{
                    try {
                        if ($grid.EditingControl -is [System.Windows.Forms.ComboBox] -and -not $grid.EditingControl.DroppedDown) {
                            $grid.EditingControl.DroppedDown = $true
                        }
                    } catch { }
                }
                $grid.BeginInvoke($openAction) | Out-Null
            } catch { }
        }
    })
    foreach ($c in $grid.Columns) { $c.SortMode = "NotSortable" }
    Enable-GridComboContainsSearch -Grid $grid -AllItems $productItems

    function Update-RowAmount($row) {
        $qty = 0.0; $rate = 0.0
        [double]::TryParse("$($row.Cells['Qty'].Value)", [ref]$qty) | Out-Null
        [double]::TryParse("$($row.Cells['Rate'].Value)", [ref]$rate) | Out-Null
        $row.Cells['Amount'].Value = [Math]::Round($qty * $rate, 2)
    }
    function Update-NetAmount {
        $total = 0.0; [double]::TryParse($txtTotal.Text, [ref]$total) | Out-Null
        $taxAmt = 0.0; [double]::TryParse($txtGstAmt.Text, [ref]$taxAmt) | Out-Null
        $txtNet.Text = [Math]::Round($total + $taxAmt, 2).ToString("N2")
    }
    function Update-Totals {
        $total = 0.0
        foreach ($row in $grid.Rows) {
            if (-not $row.IsNewRow) {
                $amt = 0.0
                [double]::TryParse("$($row.Cells['Amount'].Value)", [ref]$amt) | Out-Null
                $total += $amt
            }
        }
        $txtTotal.Text = [Math]::Round($total, 2).ToString("N2")
        Update-NetAmount
    }
    $grid.Add_CellEndEdit({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $row = $grid.Rows[$e.RowIndex]
        if ($e.ColumnIndex -eq 0) {
            $selected = "$($row.Cells['Code'].Value)".Trim()
            $code = ($selected -split ' - ')[0].Trim()
            $p = $null
            if ($code -ne "") {
                $p = $script:AllProducts | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
            }
            if (-not $p -and $selected -ne "") {
                # User ne dropdown se select kiye bina seedha poora naam type kar
                # diya (ab jo type-search kaam karta hai, isliye ye zyada hoga) -
                # agar naam se EXACTLY ek hi product match kare to usko use kar lo,
                # warna galat/adhura naam bill mein jaane se rokne ke liye cell
                # khali kar do (Add-ProductRowToGrid jaisi hi safety soch).
                $found = @($script:AllProducts | Where-Object { "$($_.Desc)" -like "*$selected*" -or "$($_.Code)" -like "*$selected*" })
                if ($found.Count -eq 1) { $p = $found[0] }
            }
            if ($p) {
                $row.Cells['Code'].Value = "$($p.Code) - $($p.Desc)"
                $row.Cells['Description'].Value = $p.Desc
                $row.Cells['Rate'].Value = $p.Rate
                if ("$($row.Cells['Qty'].Value)".Trim() -eq "") { $row.Cells['Qty'].Value = 1 }
            } elseif ($selected -ne "") {
                $row.Cells['Code'].Value = ""
                $row.Cells['Description'].Value = ""
            }
        }
        Update-RowAmount $row
        Update-Totals
    })

    # ---- Barcode / Item Code / Naam quick-add: scan or type + Enter ----
    # Works with any USB/Bluetooth barcode scanner set up as a keyboard-wedge
    # (types the code then sends Enter). Ab sirf exact Code hi nahi, product
    # NAAM ka koi bhi hissa type karke bhi Enter dabaya ja sakta hai - agar
    # ek hi item milta hai to seedha add ho jata hai, agar ek se zyada milte
    # hain to ek chhota list dikhta hai jisme se sahi item chunn sakte hain.
    # Isse item dhoondhna (300+ products ki dropdown list scroll karne se)
    # bahut fast ho jata hai. Same item dobara scan/type karne par uski Qty
    # bas 1 se badh jaati hai, naya row nahi banta.
    function Add-ProductRowToGrid($p) {
        $existingRow = $null
        foreach ($row in $grid.Rows) {
            if ($row.IsNewRow) { continue }
            $rc = ("$($row.Cells['Code'].Value)".Trim() -split ' - ')[0].Trim()
            if ($rc.ToUpper() -eq $p.Code.Trim().ToUpper()) { $existingRow = $row; break }
        }
        if ($existingRow) {
            $q = 0.0; [double]::TryParse("$($existingRow.Cells['Qty'].Value)", [ref]$q) | Out-Null
            $existingRow.Cells['Qty'].Value = $q + 1
            Update-RowAmount $existingRow
            $targetRowIdx = $existingRow.Index
        } else {
            $rowIdx = $grid.Rows.Add()
            $newRow = $grid.Rows[$rowIdx]
            $newRow.Cells['Code'].Value = "$($p.Code) - $($p.Desc)"
            $newRow.Cells['Description'].Value = $p.Desc
            $newRow.Cells['Rate'].Value = $p.Rate
            $newRow.Cells['Qty'].Value = 1
            Update-RowAmount $newRow
            $targetRowIdx = $rowIdx
        }
        Update-Totals
        # 2026-09-09 (session 13): fast keyboard-only entry - jump straight into
        # that row's Qty cell (selected, ready to overtype) so the flow is
        # "type item, Enter, type qty, Enter" with no mouse/Tab needed. The
        # Qty cell's own KeyDown (below) sends focus back to the barcode/item
        # box on Enter, closing the loop for the next item.
        try {
            $qtyColIdx = $grid.Columns['Qty'].Index
            $grid.CurrentCell = $grid.Rows[$targetRowIdx].Cells[$qtyColIdx]
            $grid.BeginEdit($true)
            if ($grid.EditingControl -is [System.Windows.Forms.TextBox]) { $grid.EditingControl.SelectAll() }
        } catch { }
    }
    # 2026-09-09 (session 13): Enter while editing the Qty cell commits that
    # qty and jumps straight back to the Barcode/Item box for the next scan/
    # type - so the whole loop (item -> Enter -> qty -> Enter -> next item)
    # never needs the mouse or Tab key.
    $grid.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'Return' -and $grid.CurrentCell -and $grid.CurrentCell.ColumnIndex -eq $grid.Columns['Qty'].Index) {
            $e.Handled = $true; $e.SuppressKeyPress = $true
            try {
                $r = $grid.CurrentCell.RowIndex
                $grid.EndEdit()
                Update-RowAmount $grid.Rows[$r]
                Update-Totals
            } catch { }
            $cboBarcode.Focus()
            $cboBarcode.SelectAll()
        }
    })
    $cboBarcode.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -ne 'Return') { return }
        $e.Handled = $true; $e.SuppressKeyPress = $true
        $typed = $cboBarcode.Text.Trim()
        if ($typed -eq "") { return }
        try {
            $p = $script:AllProducts | Where-Object { "$($_.Code)".Trim().ToUpper() -eq $typed.ToUpper() } | Select-Object -First 1
            if (-not $p) {
                # Exact code match nahi mila - ab naam (ya code ka hissa) se search karo
                $found = @($script:AllProducts | Where-Object { "$($_.Desc)" -like "*$typed*" -or "$($_.Code)" -like "*$typed*" })
                if ($found.Count -eq 1) {
                    $p = $found[0]
                } elseif ($found.Count -gt 1) {
                    $p = Show-ProductPickerDialog $found
                }
            }
            if (-not $p) {
                [System.Windows.Forms.MessageBox]::Show("'$typed' se koi item nahi mila. Product Master mein check karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null
                $cboBarcode.SelectAll()
                return
            }
            Add-ProductRowToGrid $p
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Item add karte waqt error:`n$($_.Exception.Message)", "Nav Durga Sports - Error", "OK", "Error") | Out-Null
        }
        $cboBarcode.Text = ""
        $cboBarcode.Focus()
    })

    $grpTotals = New-Object System.Windows.Forms.GroupBox
    $grpTotals.Text = "Totals"; $grpTotals.Font = $FontBold
    $grpTotals.Location = New-Object System.Drawing.Point(12, 520); $grpTotals.Size = New-Object System.Drawing.Size(910, 60)
    $grpTotals.Anchor = "Bottom, Left, Right"
    $lblTotal = New-Object System.Windows.Forms.Label
    $lblTotal.Text = "Total:"; $lblTotal.Location = New-Object System.Drawing.Point(15, 25); $lblTotal.AutoSize = $true
    $txtTotal = New-Object System.Windows.Forms.TextBox
    $txtTotal.Location = New-Object System.Drawing.Point(70, 22); $txtTotal.Size = New-Object System.Drawing.Size(110, 22); $txtTotal.ReadOnly = $true; $txtTotal.TextAlign = "Right"
    $lblGstAmt = New-Object System.Windows.Forms.Label
    $lblGstAmt.Text = "Tax Amt:"; $lblGstAmt.Location = New-Object System.Drawing.Point(200, 25); $lblGstAmt.AutoSize = $true
    $txtGstAmt = New-Object System.Windows.Forms.TextBox
    $txtGstAmt.Location = New-Object System.Drawing.Point(265, 22); $txtGstAmt.Size = New-Object System.Drawing.Size(110, 22); $txtGstAmt.Text = "0.00"; $txtGstAmt.TextAlign = "Right"
    $lblNet = New-Object System.Windows.Forms.Label
    $lblNet.Text = "Net Amount:"; $lblNet.Font = $FontBold; $lblNet.Location = New-Object System.Drawing.Point(400, 25); $lblNet.AutoSize = $true
    $txtNet = New-Object System.Windows.Forms.TextBox
    $txtNet.Location = New-Object System.Drawing.Point(490, 22); $txtNet.Size = New-Object System.Drawing.Size(130, 22); $txtNet.ReadOnly = $true
    $txtNet.Font = $FontBold; $txtNet.TextAlign = "Right"; $txtNet.BackColor = [System.Drawing.Color]::LightYellow
    $txtGstAmt.Add_TextChanged({ Update-NetAmount })
    $grpTotals.Controls.Add($lblTotal) | Out-Null
    $grpTotals.Controls.Add($txtTotal) | Out-Null
    $grpTotals.Controls.Add($lblGstAmt) | Out-Null
    $grpTotals.Controls.Add($txtGstAmt) | Out-Null
    $grpTotals.Controls.Add($lblNet) | Out-Null
    $grpTotals.Controls.Add($txtNet) | Out-Null
    $form.Controls.Add($grpTotals)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save Bill"; $btnSave.Font = $FontBold; $btnSave.Size = New-Object System.Drawing.Size(120, 34)
    $btnSave.Location = New-Object System.Drawing.Point(12, 620); $btnSave.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnSave.Anchor = "Bottom, Left"
    $btnWhatsApp = New-Object System.Windows.Forms.Button
    $btnWhatsApp.Text = "Send WhatsApp"; $btnWhatsApp.Font = $FontBold; $btnWhatsApp.Size = New-Object System.Drawing.Size(140, 34)
    $btnWhatsApp.Location = New-Object System.Drawing.Point(142, 620); $btnWhatsApp.BackColor = [System.Drawing.Color]::FromArgb(200, 230, 200)
    $btnWhatsApp.Anchor = "Bottom, Left"
    $btnPrint = New-Object System.Windows.Forms.Button
    $btnPrint.Text = "Print"; $btnPrint.Font = $FontBold; $btnPrint.Size = New-Object System.Drawing.Size(100, 34)
    $btnPrint.Location = New-Object System.Drawing.Point(292, 620); $btnPrint.BackColor = [System.Drawing.Color]::FromArgb(210, 220, 240)
    $btnPrint.Anchor = "Bottom, Left"
    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = "New Bill"; $btnNew.Font = $FontNormal; $btnNew.Size = New-Object System.Drawing.Size(110, 34)
    $btnNew.Location = New-Object System.Drawing.Point(402, 620)
    $btnNew.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(812, 620)
    $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnSave) | Out-Null
    $form.Controls.Add($btnWhatsApp) | Out-Null
    $form.Controls.Add($btnPrint) | Out-Null
    $form.Controls.Add($btnNew) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null
    $script:EditingBillNo = $null
    function Reset-Form {
        $txtBillNo.Text = Get-NextBillNo
        $dtpBillDate.Value = Get-Date
        $cboCustomer.Text = ""; $txtCity.Text = ""; $txtMobile.Text = ""; $txtAddress.Text = ""
        $lblCustBalance.Text = "-"
        $grid.Rows.Clear(); $txtGstAmt.Text = "0.00"
        Update-Totals
        $script:EditingBillNo = $null
    }
    function Load-BillIntoForm($b) {
        $txtBillNo.Text = $b.BillNo
        try { $dtpBillDate.Value = [DateTime]::ParseExact($b.BillDate, "dd-MM-yyyy", $null) } catch {}
        $cboCustomer.Text = $b.CustomerText
        $txtCity.Text = $b.City
        $txtMobile.Text = $b.Mobile
        $txtAddress.Text = $b.Address
        $grid.Rows.Clear()
        foreach ($it in $b.Items) {
            $rowIdx = $grid.Rows.Add()
            $row = $grid.Rows[$rowIdx]
            $p = $script:AllProducts | Where-Object { "$($_.Code)".Trim() -eq "$($it.Code)".Trim() } | Select-Object -First 1
            $display = if ($p) { "$($p.Code) - $($p.Desc)" } else { "$($it.Code) - $($it.Description)" }
            $row.Cells['Code'].Value = $display
            $row.Cells['Description'].Value = $it.Description
            $row.Cells['Qty'].Value = $it.Qty
            $row.Cells['Rate'].Value = $it.Rate
            $row.Cells['Amount'].Value = $it.Amount
        }
        $txtGstAmt.Text = "$($b.GstAmt)"
        Update-Totals
        Update-CustomerDetails
        $script:EditingBillNo = $b.BillNo
    }
    function Get-CurrentBillObject {
        $items = @()
        foreach ($row in $grid.Rows) {
            if (-not $row.IsNewRow) {
                $selectedVal = "$($row.Cells['Code'].Value)".Trim()
                if ($selectedVal -ne "") {
                    $code = ($selectedVal -split ' - ')[0].Trim()
                    $items += [PSCustomObject]@{
                        Code = $code; Description = "$($row.Cells['Description'].Value)"
                        Qty = "$($row.Cells['Qty'].Value)"; Rate = "$($row.Cells['Rate'].Value)"; Amount = "$($row.Cells['Amount'].Value)"
                    }
                }
            }
        }
        return [PSCustomObject]@{
            BillNo = $txtBillNo.Text; BillDate = $dtpBillDate.Value.ToString("dd-MM-yyyy"); BillType = "Rough Estimate"
            CustomerText = $cboCustomer.Text; City = $txtCity.Text; Mobile = $txtMobile.Text; Address = $txtAddress.Text
            Items = $items; Total = $txtTotal.Text; GstPct = ""; GstAmt = $txtGstAmt.Text; NetAmount = $txtNet.Text
            SavedAt = (Get-Date).ToString("s")
        }
    }

    $btnSave.Add_Click({
        if ($cboCustomer.Text.Trim() -eq "") {
            [System.Windows.Forms.MessageBox]::Show("Pehle customer select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        $itemCount = ($grid.Rows | Where-Object { -not $_.IsNewRow -and "$($_.Cells['Code'].Value)".Trim() -ne "" }).Count
        if ($itemCount -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Kam se kam ek item add karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        $bill = Get-CurrentBillObject
        Invoke-Safe { Save-CustomerMobileIfChanged -CustCode (($cboCustomer.Text -split ' - ')[0].Trim()) -Mobile $txtMobile.Text }
        $existing = @(Read-JsonArray $BillsFile)
        if ($script:EditingBillNo) {
            $existing = @($existing | Where-Object { "$($_.BillNo)" -ne "$($script:EditingBillNo)" }) + $bill
            Save-JsonArray $BillsFile $existing
            Add-AuditLog -Action "Edit" -Entity "Rough Estimate" -Details "Bill No $($bill.BillNo) - $($bill.CustomerText) - Rs. $($bill.NetAmount)"
            # 2026-09-09 (session 13): show the full bill preview right after
            # save (instead of just a "saved" popup) - the preview window's
            # own toolbar already has a Print option, so save->preview->print
            # is now one continuous flow, no separate click needed.
            Invoke-Safe { Show-BillPrintPreview $bill }
            $form.Close()
        } else {
            $existing = $existing + $bill
            Save-JsonArray $BillsFile $existing
            Add-AuditLog -Action "Create" -Entity "Rough Estimate" -Details "Bill No $($bill.BillNo) - $($bill.CustomerText) - Rs. $($bill.NetAmount)"
            Invoke-Safe { Show-BillPrintPreview $bill }
            Reset-Form
        }
    })
    $btnWhatsApp.Add_Click({
        if ($cboCustomer.Text.Trim() -eq "") {
            [System.Windows.Forms.MessageBox]::Show("Pehle customer select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        if ("$($txtMobile.Text)".Trim() -eq "") {
            [System.Windows.Forms.MessageBox]::Show("Mobile No. wala box khali hai.`nUpar 'Mobile No.' box mein number likhein, phir Send WhatsApp dabayein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        Invoke-Safe { Save-CustomerMobileIfChanged -CustCode (($cboCustomer.Text -split ' - ')[0].Trim()) -Mobile $txtMobile.Text }
        $partyName = ($cboCustomer.Text -split ' - ')[1]
        $itemLines = ""
        foreach ($row in $grid.Rows) {
            if (-not $row.IsNewRow -and "$($row.Cells['Code'].Value)".Trim() -ne "") {
                $itemLines += "$($row.Cells['Description'].Value) x $($row.Cells['Qty'].Value) = Rs. $($row.Cells['Amount'].Value)`n"
            }
        }
        $msg = "Vani, Meerut - DASH X`nRough Estimate`nBill No: $($txtBillNo.Text)`nDate: $($dtpBillDate.Value.ToString('dd-MM-yyyy'))`nParty: $partyName`n`n$itemLines`nNet Amount: Rs. $($txtNet.Text)`n`nThank you for your business!"
        $imgPath = Get-BillImage (Get-CurrentBillObject)
        if (-not $imgPath) {
            [System.Windows.Forms.MessageBox]::Show("Bill ki asli image (parchi) nahi ban payi is baar - sirf text WhatsApp par bhej rahe hain.", "Nav Durga Sports", "OK", "Warning") | Out-Null
        }
        Send-WhatsAppMessage -Mobile $txtMobile.Text -Message $msg -ImagePath $imgPath
    })
    $btnPrint.Add_Click({
        if ($cboCustomer.Text.Trim() -eq "") {
            [System.Windows.Forms.MessageBox]::Show("Pehle customer select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        $itemCount = ($grid.Rows | Where-Object { -not $_.IsNewRow -and "$($_.Cells['Code'].Value)".Trim() -ne "" }).Count
        if ($itemCount -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Kam se kam ek item add karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        Show-BillPrintPreview (Get-CurrentBillObject)
    })
    $btnNew.Add_Click({ Reset-Form })
    $btnClose.Add_Click({ $form.Close() })

    # ---- Keyboard shortcuts: F2 New Bill, F3 Save, F5 Print, F8 Find Item,
    # F9 Find Bill, F4 Customer List, Enter = jump to next field. Apni alag
    # line mein (buttons ke upar) taaki Close button kabhi disturb na ho,
    # aur bada/bold/red taaki saaf saaf dikhe.
    $lblShortcuts = New-Object System.Windows.Forms.Label
    $lblShortcuts.Text = "F2 = New Bill   F3 = Save   F4 = Customer List   F5 = Print   F8 = Find Item   F9 = Find Bill   Enter = Next Field"
    $lblShortcuts.Font = New-Object System.Drawing.Font("Tahoma", 9.5, [System.Drawing.FontStyle]::Bold)
    $lblShortcuts.ForeColor = [System.Drawing.Color]::FromArgb(200, 0, 0)
    $lblShortcuts.AutoSize = $false
    $lblShortcuts.Location = New-Object System.Drawing.Point(12, 586)
    $lblShortcuts.Size = New-Object System.Drawing.Size(910, 26)
    $lblShortcuts.Anchor = "Bottom, Left, Right"
    $form.Controls.Add($lblShortcuts) | Out-Null

    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'F2') { $btnNew.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'F3') { $btnSave.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'F5') { $btnPrint.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'F8') { $btnFindItem.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'F9') { $btnFindBill.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'F4') {
            Invoke-Safe {
                $picked = Show-CustomerPickerForm
                if ($picked) {
                    $cboCustomer.Text = "$($picked.Code) - $($picked.Name)"
                    Update-CustomerDetails
                    $cboCustomer.Focus()
                }
            }
            $e.Handled = $true; $e.SuppressKeyPress = $true
        }
        elseif ($e.KeyCode -eq 'Return' -and $form.ActiveControl -ne $cboBarcode) {
            $ac = $form.ActiveControl
            if ($ac -and ($ac -is [System.Windows.Forms.TextBox] -or $ac -is [System.Windows.Forms.ComboBox] -or $ac -is [System.Windows.Forms.DateTimePicker]) -and -not ($ac -is [System.Windows.Forms.TextBox] -and $ac.ReadOnly)) {
                $form.SelectNextControl($ac, $true, $true, $true, $true) | Out-Null
                $e.Handled = $true; $e.SuppressKeyPress = $true
            }
        }
    })

    Reset-Form
    if ($Existing) { Load-BillIntoForm $Existing }
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  SELECT CUSTOMER (quick picker) - F4 se bill/voucher screens ke andar se
#  khulta hai; ek customer choose karke turant wapas us screen mein bhar
#  deta hai, alag se Customer Master jaisi edit screen nahi khulti.
# ============================================================================
function Show-CustomerPickerForm {
    $script:PickedCustomer = $null
    $frm = New-Object System.Windows.Forms.Form
    $frm.Text = "Select Customer"
    $frm.Size = New-Object System.Drawing.Size(820, 520)
    $frm.MinimumSize = New-Object System.Drawing.Size(820, 520)
    $frm.StartPosition = "CenterScreen"
    $frm.FormBorderStyle = "Sizable"
    $frm.BackColor = [System.Drawing.SystemColors]::Control
    $frm.Font = $FontNormal
    $frm.Controls.Add((New-TitleBanner "SELECT CUSTOMER" 804))

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search (Name / Mobile / City):"
    $lblSearch.Font = $FontBold
    $lblSearch.Location = New-Object System.Drawing.Point(12, 55); $lblSearch.AutoSize = $true
    $frm.Controls.Add($lblSearch)
    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Font = $FontNormal
    $txtSearch.Location = New-Object System.Drawing.Point(255, 52); $txtSearch.Size = New-Object System.Drawing.Size(300, 24)
    $frm.Controls.Add($txtSearch)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 85); $grid.Size = New-Object System.Drawing.Size(780, 345)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Code", "Code") | Out-Null
    $grid.Columns.Add("Name", "Name") | Out-Null
    $grid.Columns.Add("City", "City") | Out-Null
    $grid.Columns.Add("Mobile", "Mobile") | Out-Null
    $grid.Columns["Code"].Width = 70; $grid.Columns["Name"].Width = 270; $grid.Columns["City"].Width = 150; $grid.Columns["Mobile"].Width = 130
    $frm.Controls.Add($grid)

    $script:AllCustomers = Get-AllCustomers
    $allCust = $script:AllCustomers
    function Refresh-PickerGrid {
        $grid.Rows.Clear()
        $q = $txtSearch.Text.Trim()
        $rows = if ($q -eq "") { $allCust } else {
            $allCust | Where-Object { "$($_.Name)" -like "*$q*" -or "$($_.Mobile)" -like "*$q*" -or "$($_.City)" -like "*$q*" -or "$($_.Code)" -like "*$q*" }
        }
        foreach ($c in $rows) {
            $grid.Rows.Add($c.Code, $c.Name, $c.City, $c.Mobile) | Out-Null
        }
    }
    $txtSearch.Add_TextChanged({ Refresh-PickerGrid })
    Refresh-PickerGrid

    $btnSelect = New-Object System.Windows.Forms.Button
    $btnSelect.Text = "Select"; $btnSelect.Font = $FontBold; $btnSelect.Size = New-Object System.Drawing.Size(110, 34)
    $btnSelect.Location = New-Object System.Drawing.Point(12, 442); $btnSelect.Anchor = "Bottom, Left"
    $btnSelect.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $frm.Controls.Add($btnSelect)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"; $btnCancel.Font = $FontNormal; $btnCancel.Size = New-Object System.Drawing.Size(110, 34)
    $btnCancel.Location = New-Object System.Drawing.Point(682, 442); $btnCancel.Anchor = "Bottom, Right"
    $frm.Controls.Add($btnCancel)

    $doSelect = {
        if ($grid.CurrentRow) {
            $code = "$($grid.CurrentRow.Cells['Code'].Value)".Trim()
            $script:PickedCustomer = $allCust | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
            $frm.DialogResult = [System.Windows.Forms.DialogResult]::OK
        }
    }
    $btnSelect.Add_Click($doSelect)
    $grid.Add_CellDoubleClick({ & $doSelect })
    $btnCancel.Add_Click({ $frm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel })
    $frm.AcceptButton = $btnSelect
    $frm.Add_Shown({ $txtSearch.Focus() })

    $frm.ShowDialog() | Out-Null
    return $script:PickedCustomer
}

# ============================================================================
#  CUSTOMER MASTER FORM
# ============================================================================
function Show-CustomerInfoDialog {
    # 2026-09-11 (session 21): Vineet ke bheje purane software screenshot
    # jaisa "Customer Info" popup - Add New aur Edit dono isi ek dialog se
    # hote hain, sath mein naye fields (State/Pin Code/GSTIN/Contact
    # Person/Transport Name/Landline/Email) bhi.
    param($ExistingCust)
    $isOld = $ExistingCust -and ("$($ExistingCust.Source)" -eq "Old")
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = if ($ExistingCust) { "Customer Info - $($ExistingCust.Code)" } else { "Add New Customer" }
    $dlg.Size = New-Object System.Drawing.Size(580, 440)
    $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.Font = $FontNormal
    $dlg.Controls.Add((New-TitleBanner "CUSTOMER INFO" 564))

    $leftLabels = @("Customer Description:", "Customer Street1:", "Customer Street2:", "Customer City:", "Customer Pin Code:", "Customer State:")
    $leftKeys   = @("Name", "Add1", "Add2", "City", "PinCode", "State")
    $leftBoxes = @{}
    for ($i = 0; $i -lt $leftLabels.Count; $i++) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $leftLabels[$i]; $lbl.Location = New-Object System.Drawing.Point(15, (55 + $i * 34)); $lbl.AutoSize = $true
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(160, (52 + $i * 34)); $tb.Size = New-Object System.Drawing.Size(130, 22)
        if ($ExistingCust) { $tb.Text = "$($ExistingCust.($leftKeys[$i]))" }
        if ($leftKeys[$i] -eq "Name" -and $isOld) {
            # Purane (DBF) customer ka naam yahan se edit nahi hota - DBF
            # file kabhi nahi chhedi jaati.
            $tb.ReadOnly = $true; $tb.BackColor = [System.Drawing.SystemColors]::Control
        }
        $dlg.Controls.Add($lbl); $dlg.Controls.Add($tb)
        $leftBoxes[$leftKeys[$i]] = $tb
    }

    $lblBalTitle = New-Object System.Windows.Forms.Label
    $lblBalTitle.Text = "Customer Opening Bal:"; $lblBalTitle.Location = New-Object System.Drawing.Point(15, (55 + 6 * 34)); $lblBalTitle.AutoSize = $true
    $lblBalValue = New-Object System.Windows.Forms.Label
    $balText = "-"
    if ($ExistingCust) {
        $ledgerRows = Get-CustomerLedger -CustCode $ExistingCust.Code
        if ($ledgerRows.Count -gt 0) { $balText = "Rs. $($ledgerRows[$ledgerRows.Count - 1].Balance)" } else { $balText = "Rs. 0.00" }
    }
    $lblBalValue.Text = $balText; $lblBalValue.Font = $FontBold; $lblBalValue.ForeColor = $ColorVfpBlue
    $lblBalValue.Location = New-Object System.Drawing.Point(160, (55 + 6 * 34)); $lblBalValue.AutoSize = $true
    $dlg.Controls.Add($lblBalTitle); $dlg.Controls.Add($lblBalValue)

    $rightLabels = @("GSTIN:", "Contact Person:", "Transport Name:", "Landline:", "Mobile:", "Email Address:")
    $rightKeys   = @("GSTIN", "ContactPerson", "TransportName", "Landline", "Mobile", "Email")
    $rightBoxes = @{}
    for ($i = 0; $i -lt $rightLabels.Count; $i++) {
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = $rightLabels[$i]; $lbl.Location = New-Object System.Drawing.Point(320, (55 + $i * 34)); $lbl.AutoSize = $true
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(435, (52 + $i * 34)); $tb.Size = New-Object System.Drawing.Size(125, 22)
        if ($ExistingCust) { $tb.Text = "$($ExistingCust.($rightKeys[$i]))" }
        $dlg.Controls.Add($lbl); $dlg.Controls.Add($tb)
        $rightBoxes[$rightKeys[$i]] = $tb
    }

    if ($isOld) {
        $lblNote = New-Object System.Windows.Forms.Label
        $lblNote.Text = "(Purana customer - naam DBF se aata hai, edit nahi hoga)"
        $lblNote.Location = New-Object System.Drawing.Point(15, 302); $lblNote.AutoSize = $true
        $lblNote.ForeColor = [System.Drawing.Color]::DimGray
        $dlg.Controls.Add($lblNote)
    }

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"; $btnOk.Font = $FontBold; $btnOk.Location = New-Object System.Drawing.Point(150, 355); $btnOk.Size = New-Object System.Drawing.Size(100, 32)
    $btnOk.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel"; $btnCancel.Location = New-Object System.Drawing.Point(260, 355); $btnCancel.Size = New-Object System.Drawing.Size(100, 32)
    $btnDlgClose = New-Object System.Windows.Forms.Button
    $btnDlgClose.Text = "Close"; $btnDlgClose.Location = New-Object System.Drawing.Point(370, 355); $btnDlgClose.Size = New-Object System.Drawing.Size(100, 32)
    $dlg.Controls.Add($btnOk) | Out-Null
    $dlg.Controls.Add($btnCancel) | Out-Null
    $dlg.Controls.Add($btnDlgClose) | Out-Null

    $btnOk.Add_Click({
        try {
            if (-not $isOld -and $leftBoxes["Name"].Text.Trim() -eq "") {
                [System.Windows.Forms.MessageBox]::Show("Customer Description dalna zaroori hai.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
            }
            if (-not $ExistingCust) {
                $newCode = Get-NextNewCode -Prefix "N" -JsonFile $NewCustFile
                $obj = [PSCustomObject]@{
                    Code = $newCode; Name = $leftBoxes["Name"].Text.Trim(); City = $leftBoxes["City"].Text.Trim()
                    Mobile = $rightBoxes["Mobile"].Text.Trim(); Add1 = $leftBoxes["Add1"].Text.Trim(); Add2 = $leftBoxes["Add2"].Text.Trim()
                    State = $leftBoxes["State"].Text.Trim(); PinCode = $leftBoxes["PinCode"].Text.Trim()
                    GSTIN = $rightBoxes["GSTIN"].Text.Trim(); ContactPerson = $rightBoxes["ContactPerson"].Text.Trim()
                    TransportName = $rightBoxes["TransportName"].Text.Trim(); Landline = $rightBoxes["Landline"].Text.Trim()
                    Email = $rightBoxes["Email"].Text.Trim()
                }
                $existing = Read-JsonArray $NewCustFile
                $existing = @($existing) + $obj
                Save-JsonArray $NewCustFile $existing
                Add-AuditLog -Action "Create" -Entity "Customer" -Details "$($obj.Code) - $($obj.Name) - $($obj.City)"
            } elseif ($isOld) {
                $overrides = @(Read-JsonArray $CustomerOverridesFile) | Where-Object { "$($_.Code)".Trim() -ne "$($ExistingCust.Code)".Trim() }
                $ovObj = [PSCustomObject]@{
                    Code = $ExistingCust.Code; City = $leftBoxes["City"].Text.Trim()
                    Mobile = $rightBoxes["Mobile"].Text.Trim(); Add1 = $leftBoxes["Add1"].Text.Trim(); Add2 = $leftBoxes["Add2"].Text.Trim()
                    State = $leftBoxes["State"].Text.Trim(); PinCode = $leftBoxes["PinCode"].Text.Trim()
                    GSTIN = $rightBoxes["GSTIN"].Text.Trim(); ContactPerson = $rightBoxes["ContactPerson"].Text.Trim()
                    TransportName = $rightBoxes["TransportName"].Text.Trim(); Landline = $rightBoxes["Landline"].Text.Trim()
                    Email = $rightBoxes["Email"].Text.Trim()
                }
                $overrides = @($overrides) + $ovObj
                Save-JsonArray $CustomerOverridesFile $overrides
                Add-AuditLog -Action "Edit" -Entity "Customer" -Details "$($ExistingCust.Code) - $($ExistingCust.Name) - Info update"
            } else {
                $all = @(Read-JsonArray $NewCustFile)
                $all = $all | ForEach-Object {
                    if ("$($_.Code)".Trim() -eq "$($ExistingCust.Code)".Trim()) {
                        [PSCustomObject]@{
                            Code = $_.Code; Name = $leftBoxes["Name"].Text.Trim(); City = $leftBoxes["City"].Text.Trim()
                            Mobile = $rightBoxes["Mobile"].Text.Trim(); Add1 = $leftBoxes["Add1"].Text.Trim(); Add2 = $leftBoxes["Add2"].Text.Trim()
                            State = $leftBoxes["State"].Text.Trim(); PinCode = $leftBoxes["PinCode"].Text.Trim()
                            GSTIN = $rightBoxes["GSTIN"].Text.Trim(); ContactPerson = $rightBoxes["ContactPerson"].Text.Trim()
                            TransportName = $rightBoxes["TransportName"].Text.Trim(); Landline = $rightBoxes["Landline"].Text.Trim()
                            Email = $rightBoxes["Email"].Text.Trim()
                        }
                    } else { $_ }
                }
                Save-JsonArray $NewCustFile $all
                Add-AuditLog -Action "Edit" -Entity "Customer" -Details "$($ExistingCust.Code) - $($leftBoxes["Name"].Text.Trim()) - Info update"
            }
            $dlg.Tag = "saved"
            $dlg.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Save karte waqt error:`n$($_.Exception.Message)", "Nav Durga Sports - Error", "OK", "Error") | Out-Null
        }
    }.GetNewClosure())
    $btnCancel.Add_Click({ $dlg.Close() })
    $btnDlgClose.Add_Click({ $dlg.Close() })
    $dlg.ShowDialog($form) | Out-Null
    return ($dlg.Tag -eq "saved")
}

function Show-CustomerMasterForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Customer Master"
    $form.Size = New-Object System.Drawing.Size(820, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(820, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "CUSTOMER LIST" 804))

    # ---- Search In / Look For / Find / Clear / Close - purane software ki
    # Customer List screen jaisa (Vineet ke screenshot se), 2026-09-11.
    $lblSearchIn = New-Object System.Windows.Forms.Label
    $lblSearchIn.Text = "Search In:"; $lblSearchIn.Font = $FontBold; $lblSearchIn.AutoSize = $true
    $lblSearchIn.Location = New-Object System.Drawing.Point(12, 54)
    $cboSearchIn = New-Object System.Windows.Forms.ComboBox
    $cboSearchIn.DropDownStyle = "DropDownList"
    $cboSearchIn.Items.AddRange(@("Customer Description", "Customer Code", "Customer Street1", "Customer Street2", "Customer City", "Customer State", "Customer Mobile"))
    $cboSearchIn.SelectedIndex = 0
    $cboSearchIn.Location = New-Object System.Drawing.Point(95, 51); $cboSearchIn.Size = New-Object System.Drawing.Size(165, 24)
    $lblLookFor = New-Object System.Windows.Forms.Label
    $lblLookFor.Text = "Look For:"; $lblLookFor.Font = $FontBold; $lblLookFor.AutoSize = $true
    $lblLookFor.Location = New-Object System.Drawing.Point(270, 54)
    $txtLookFor = New-Object System.Windows.Forms.TextBox
    $txtLookFor.Location = New-Object System.Drawing.Point(335, 51); $txtLookFor.Size = New-Object System.Drawing.Size(175, 24)
    $btnFind = New-Object System.Windows.Forms.Button
    $btnFind.Text = "Find"; $btnFind.Font = $FontBold; $btnFind.Size = New-Object System.Drawing.Size(65, 27)
    $btnFind.Location = New-Object System.Drawing.Point(520, 49); $btnFind.BackColor = [System.Drawing.Color]::FromArgb(210, 225, 245)
    $btnClear = New-Object System.Windows.Forms.Button
    $btnClear.Text = "Clear"; $btnClear.Font = $FontNormal; $btnClear.Size = New-Object System.Drawing.Size(65, 27)
    $btnClear.Location = New-Object System.Drawing.Point(590, 49)
    $btnTopClose = New-Object System.Windows.Forms.Button
    $btnTopClose.Text = "Close"; $btnTopClose.Font = $FontNormal; $btnTopClose.Size = New-Object System.Drawing.Size(65, 27)
    $btnTopClose.Location = New-Object System.Drawing.Point(660, 49)
    $form.Controls.Add($lblSearchIn) | Out-Null
    $form.Controls.Add($cboSearchIn) | Out-Null
    $form.Controls.Add($lblLookFor) | Out-Null
    $form.Controls.Add($txtLookFor) | Out-Null
    $form.Controls.Add($btnFind) | Out-Null
    $form.Controls.Add($btnClear) | Out-Null
    $form.Controls.Add($btnTopClose) | Out-Null

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 84); $grid.Size = New-Object System.Drawing.Size(780, 366)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Font = New-Object System.Drawing.Font("Tahoma", 11)
    $grid.RowTemplate.Height = 26
    $grid.Columns.Add("Code", "Code") | Out-Null
    $grid.Columns.Add("Name", "Customer Description") | Out-Null
    $grid.Columns.Add("Add1", "Customer Street1") | Out-Null
    $grid.Columns.Add("Add2", "Customer Street2") | Out-Null
    $grid.Columns.Add("City", "Customer City") | Out-Null
    $grid.Columns.Add("State", "Customer State") | Out-Null
    $grid.Columns.Add("Mobile", "Mobile No.") | Out-Null
    $grid.Columns["Code"].Width = 65; $grid.Columns["Name"].Width = 175; $grid.Columns["Add1"].Width = 110
    $grid.Columns["Add2"].Width = 100; $grid.Columns["City"].Width = 100; $grid.Columns["State"].Width = 100; $grid.Columns["Mobile"].Width = 105
    $form.Controls.Add($grid)

    function Load-GridRows {
        param($Customers)
        $grid.Rows.Clear()
        foreach ($c in $Customers) {
            $grid.Rows.Add($c.Code, $c.Name, $c.Add1, $c.Add2, $c.City, $c.State, $c.Mobile) | Out-Null
        }
        $lblCount.Text = "Total Customers: $($grid.Rows.Count)"
    }
    function Refresh-Grid {
        $script:AllCustomers = Get-AllCustomers
        Load-GridRows $script:AllCustomers
    }

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(12, 458); $lblCount.AutoSize = $true; $lblCount.Font = $FontNormal
    $lblCount.Anchor = "Bottom, Left"

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "Add New Customer"; $btnAdd.Font = $FontBold; $btnAdd.Size = New-Object System.Drawing.Size(160, 34)
    $btnAdd.Location = New-Object System.Drawing.Point(12, 480); $btnAdd.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnAdd.Anchor = "Bottom, Left"
    $form.Controls.Add($lblCount) | Out-Null
    $form.Controls.Add($btnAdd) | Out-Null

    $btnAdd.Add_Click({
        if (Show-CustomerInfoDialog $null) { Refresh-Grid }
    })
    $grid.Add_CellDoubleClick({
        if ($grid.CurrentRow) {
            $code = "$($grid.CurrentRow.Cells['Code'].Value)".Trim()
            $cust = $script:AllCustomers | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
            if ($cust -and (Show-CustomerInfoDialog $cust)) { Refresh-Grid }
        }
    })
    $btnFind.Add_Click({
        $q = $txtLookFor.Text.Trim()
        if ($q -eq "") { Load-GridRows $script:AllCustomers; return }
        $field = switch ($cboSearchIn.Text) {
            "Customer Code" { "Code" }
            "Customer Street1" { "Add1" }
            "Customer Street2" { "Add2" }
            "Customer City" { "City" }
            "Customer State" { "State" }
            "Customer Mobile" { "Mobile" }
            default { "Name" }
        }
        $filtered = $script:AllCustomers | Where-Object { "$($_.$field)" -like "*$q*" }
        Load-GridRows $filtered
    })
    $txtLookFor.Add_TextChanged({ $btnFind.PerformClick() })
    $txtLookFor.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq "Enter") { $btnFind.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
    })
    $btnClear.Add_Click({
        $txtLookFor.Text = ""
        $cboSearchIn.SelectedIndex = 0
        Load-GridRows $script:AllCustomers
    })
    $btnTopClose.Add_Click({ $form.Close() })

    Refresh-Grid
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  PRODUCT MASTER FORM
# ============================================================================
function Show-ProductMasterForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Product Master"
    $form.Size = New-Object System.Drawing.Size(760, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "PRODUCT MASTER (DASH X)" 744))

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 50); $grid.Size = New-Object System.Drawing.Size(720, 400)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Code", "Code") | Out-Null
    $grid.Columns.Add("Desc", "Description") | Out-Null
    $grid.Columns.Add("Rate", "Sale Rate") | Out-Null
    $grid.Columns.Add("Unit", "Unit") | Out-Null
    $grid.Columns.Add("Gst", "Tax %") | Out-Null
    $grid.Columns["Code"].Width = 80; $grid.Columns["Desc"].Width = 320; $grid.Columns["Rate"].Width = 100
    $grid.Columns["Unit"].Width = 80; $grid.Columns["Gst"].Width = 80
    $form.Controls.Add($grid)

    function Refresh-Grid {
        $grid.Rows.Clear()
        $script:AllProducts = Get-AllProducts
        foreach ($p in $script:AllProducts) {
            $grid.Rows.Add($p.Code, $p.Desc, $p.Rate, $p.Unit, $p.Gst) | Out-Null
        }
    }

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(12, 458); $lblCount.AutoSize = $true; $lblCount.Font = $FontNormal
    $lblCount.Anchor = "Bottom, Left"

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "Add New Product"; $btnAdd.Font = $FontBold; $btnAdd.Size = New-Object System.Drawing.Size(160, 34)
    $btnAdd.Location = New-Object System.Drawing.Point(12, 480); $btnAdd.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnAdd.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(642, 480)
    $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($lblCount) | Out-Null
    $form.Controls.Add($btnAdd) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null
    $btnAdd.Add_Click({
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "Add New Product"; $dlg.Size = New-Object System.Drawing.Size(400, 280)
        $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
        $dlg.Font = $FontNormal
        $labels = @("Description:", "Sale Rate:", "Unit (e.g. DZ/PC):", "Tax %:")
        $boxes = @()
        for ($i = 0; $i -lt $labels.Count; $i++) {
            $lbl = New-Object System.Windows.Forms.Label
            $lbl.Text = $labels[$i]; $lbl.Location = New-Object System.Drawing.Point(15, (20 + $i * 40)); $lbl.AutoSize = $true
            $tb = New-Object System.Windows.Forms.TextBox
            $tb.Location = New-Object System.Drawing.Point(150, (17 + $i * 40)); $tb.Size = New-Object System.Drawing.Size(210, 22)
            $dlg.Controls.Add($lbl); $dlg.Controls.Add($tb); $boxes += $tb
        }
        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = "Save"; $btnOk.Font = $FontBold; $btnOk.Location = New-Object System.Drawing.Point(150, 190); $btnOk.Size = New-Object System.Drawing.Size(100, 32)
        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = "Cancel"; $btnCancel.Location = New-Object System.Drawing.Point(260, 190); $btnCancel.Size = New-Object System.Drawing.Size(100, 32)
        $dlg.Controls.Add($btnOk) | Out-Null
        $dlg.Controls.Add($btnCancel) | Out-Null
        $btnOk.Add_Click({
            try {
                if ($boxes[0].Text.Trim() -eq "") {
                    [System.Windows.Forms.MessageBox]::Show("Description dalna zaroori hai.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
                }
                $newCode = Get-NextNewCode -Prefix "N" -JsonFile $NewProdFile
                $obj = [PSCustomObject]@{
                    Code = $newCode; Desc = $boxes[0].Text.Trim(); Desc2 = ""
                    Rate = $boxes[1].Text.Trim(); Unit = $boxes[2].Text.Trim(); Gst = $boxes[3].Text.Trim()
                }
                $existing = Read-JsonArray $NewProdFile
                $existing = @($existing) + $obj
                Save-JsonArray $NewProdFile $existing
                Add-AuditLog -Action "Create" -Entity "Product" -Details "$($obj.Code) - $($obj.Desc) - Rate Rs. $($obj.Rate)"
                $dlg.Tag = "saved"
                $dlg.Close()
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Save karte waqt error:`n$($_.Exception.Message)", "Nav Durga Sports - Error", "OK", "Error") | Out-Null
            }
        }.GetNewClosure())
        $btnCancel.Add_Click({ $dlg.Close() })
        $dlg.ShowDialog($form) | Out-Null
        if ($dlg.Tag -eq "saved") { Refresh-Grid; $lblCount.Text = "Total Products: $($grid.Rows.Count)" }
    })
    $btnClose.Add_Click({ $form.Close() })

    Refresh-Grid
    $lblCount.Text = "Total Products: $($grid.Rows.Count)"
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  BILL LIST / HISTORY FORM
# ============================================================================
function Show-BillListForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Rough Estimate List"
    $form.Size = New-Object System.Drawing.Size(900, 600)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 600)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "ROUGH ESTIMATE LIST" 884))

    # 2026-09-09 (session 12): quick search bar - filters live as you type by
    # Bill No, Customer name/code, City, Mobile, or Date (contains match,
    # same idea as the customer/item "contains" search elsewhere in the app).
    # This is a plain TextBox driving a DataGridView refill (not an
    # AutoComplete combo), so it carries none of the ComboBox
    # freeze/reentrancy risk that combo boxes needed BeginInvoke for.
    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search (Bill No / Customer / City / Mobile / Date):"
    $lblSearch.Location = New-Object System.Drawing.Point(12, 54); $lblSearch.AutoSize = $true
    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(300, 51); $txtSearch.Size = New-Object System.Drawing.Size(300, 24); $txtSearch.Font = $FontNormal
    $btnClearSearch = New-Object System.Windows.Forms.Button
    $btnClearSearch.Text = "Clear"; $btnClearSearch.Location = New-Object System.Drawing.Point(608, 50); $btnClearSearch.Size = New-Object System.Drawing.Size(70, 26)
    $form.Controls.Add($lblSearch) | Out-Null
    $form.Controls.Add($txtSearch) | Out-Null
    $form.Controls.Add($btnClearSearch) | Out-Null

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 84); $grid.Size = New-Object System.Drawing.Size(860, 346)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("BillNo", "R.E. No") | Out-Null
    $grid.Columns.Add("BillDate", "R.E. Date") | Out-Null
    $grid.Columns.Add("CustCode", "Cust.Code") | Out-Null
    $grid.Columns.Add("Customer", "Customer Description") | Out-Null
    $grid.Columns.Add("City", "Customer City") | Out-Null
    $grid.Columns.Add("Mobile", "Whatsapp No.") | Out-Null
    $grid.Columns.Add("NetAmount", "R.E. Amount") | Out-Null
    $grid.Columns.Add("WA", "Whatsapp Flag") | Out-Null
    $grid.Columns["BillNo"].Width = 70; $grid.Columns["BillDate"].Width = 90; $grid.Columns["CustCode"].Width = 75
    $grid.Columns["Customer"].Width = 210; $grid.Columns["City"].Width = 110; $grid.Columns["Mobile"].Width = 110; $grid.Columns["NetAmount"].Width = 110
    $grid.Columns["WA"].Width = 90; $grid.Columns["WA"].DefaultCellStyle.Alignment = "MiddleCenter"
    $form.Controls.Add($grid)

    $script:BillListData = @()
    $script:AllCustomers = Get-AllCustomers
    function Load-Grid {
        $grid.Rows.Clear()
        $script:BillListData = @(Read-JsonArray $BillsFile) | Sort-Object { [int]($_.BillNo -replace '[^0-9]','') } -Descending
        $filterText = $txtSearch.Text.Trim()
        $dataToShow = $script:BillListData
        if ($filterText -ne "") {
            $dataToShow = @($script:BillListData | Where-Object {
                "$($_.BillNo)" -like "*$filterText*" -or
                "$($_.CustomerText)" -like "*$filterText*" -or
                "$($_.City)" -like "*$filterText*" -or
                "$($_.Mobile)" -like "*$filterText*" -or
                "$($_.BillDate)" -like "*$filterText*"
            })
        }
        foreach ($b in $dataToShow) {
            $parts = "$($b.CustomerText)" -split ' - '
            $custCode = $parts[0]
            $custDesc = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            $liveCust = $script:AllCustomers | Where-Object { "$($_.Code)".Trim() -eq "$custCode".Trim() } | Select-Object -First 1
            $displayMobile = if ($liveCust -and "$($liveCust.Mobile)".Trim() -ne "") { $liveCust.Mobile } else { $b.Mobile }
            $waFlag = if ($b.WhatsAppSent -eq $true) { "$([char]0x2714) Sent" } else { "$([char]0x25CB) Pending" }
            $rowIdx = $grid.Rows.Add($b.BillNo, $b.BillDate, $custCode, $custDesc, $b.City, $displayMobile, $b.NetAmount, $waFlag)
            $grid.Rows[$rowIdx].Cells["WA"].Style.ForeColor = if ($waFlag -eq "Sent") { [System.Drawing.Color]::FromArgb(37, 130, 60) } else { [System.Drawing.Color]::FromArgb(180, 120, 0) }
        }
        $lblCount.Text = "Total Bills: $($grid.Rows.Count)"
    }
    $txtSearch.Add_TextChanged({ Load-Grid })
    $btnClearSearch.Add_Click({ $txtSearch.Text = ""; $txtSearch.Focus() })

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Text = "Total Bills: 0"
    $lblCount.Location = New-Object System.Drawing.Point(12, 436); $lblCount.AutoSize = $true
    $lblCount.Anchor = "Bottom, Left"

    function Get-SelectedBill {
        if ($grid.SelectedRows.Count -eq 0) { return $null }
        $billNo = $grid.SelectedRows[0].Cells["BillNo"].Value
        return $script:BillListData | Where-Object { "$($_.BillNo)" -eq "$billNo" } | Select-Object -First 1
    }

    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = "New Rough Estimate"; $btnNew.Font = $FontBold; $btnNew.Size = New-Object System.Drawing.Size(170, 30)
    $btnNew.Location = New-Object System.Drawing.Point(12, 462); $btnNew.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnNew.Anchor = "Bottom, Left"
    $btnEdit = New-Object System.Windows.Forms.Button
    $btnEdit.Text = "Edit"; $btnEdit.Font = $FontBold; $btnEdit.Size = New-Object System.Drawing.Size(80, 30)
    $btnEdit.Location = New-Object System.Drawing.Point(192, 462)
    $btnEdit.Anchor = "Bottom, Left"
    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete"; $btnDelete.Font = $FontBold; $btnDelete.Size = New-Object System.Drawing.Size(80, 30)
    $btnDelete.Location = New-Object System.Drawing.Point(282, 462); $btnDelete.BackColor = [System.Drawing.Color]::FromArgb(240, 210, 210)
    $btnDelete.Anchor = "Bottom, Left"
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(80, 30)
    $btnRefresh.Location = New-Object System.Drawing.Point(372, 462)
    $btnRefresh.Anchor = "Bottom, Left"

    $btnView = New-Object System.Windows.Forms.Button
    $btnView.Text = "View Details"; $btnView.Font = $FontBold; $btnView.Size = New-Object System.Drawing.Size(130, 34)
    $btnView.Location = New-Object System.Drawing.Point(12, 504)
    $btnView.Anchor = "Bottom, Left"
    $btnResend = New-Object System.Windows.Forms.Button
    $btnResend.Text = "Resend WhatsApp"; $btnResend.Font = $FontBold; $btnResend.Size = New-Object System.Drawing.Size(150, 34)
    $btnResend.Location = New-Object System.Drawing.Point(152, 504); $btnResend.BackColor = [System.Drawing.Color]::FromArgb(200, 230, 200)
    $btnResend.Anchor = "Bottom, Left"
    $btnPrint = New-Object System.Windows.Forms.Button
    $btnPrint.Text = "Print"; $btnPrint.Font = $FontBold; $btnPrint.Size = New-Object System.Drawing.Size(100, 34)
    $btnPrint.Location = New-Object System.Drawing.Point(312, 504); $btnPrint.BackColor = [System.Drawing.Color]::FromArgb(210, 220, 240)
    $btnPrint.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(782, 504)
    $btnClose.Anchor = "Bottom, Right"

    $form.Controls.Add($lblCount) | Out-Null
    $form.Controls.Add($btnNew) | Out-Null
    $form.Controls.Add($btnEdit) | Out-Null
    $form.Controls.Add($btnDelete) | Out-Null
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnView) | Out-Null
    $form.Controls.Add($btnResend) | Out-Null
    $form.Controls.Add($btnPrint) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $btnNew.Add_Click({ Invoke-Safe { Show-SalesBillForm }; Load-Grid })
    $btnEdit.Add_Click({
        $b = Get-SelectedBill
        if (-not $b) { [System.Windows.Forms.MessageBox]::Show("Pehle ek rough estimate select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        Invoke-Safe { Show-SalesBillForm -Existing $b }
        Load-Grid
    })
    $btnDelete.Add_Click({
        $b = Get-SelectedBill
        if (-not $b) { [System.Windows.Forms.MessageBox]::Show("Pehle ek rough estimate select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Bill No $($b.BillNo) delete karein?", "Nav Durga Sports", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            $remaining = @(Read-JsonArray $BillsFile) | Where-Object { "$($_.BillNo)" -ne "$($b.BillNo)" }
            Save-JsonArray $BillsFile $remaining
            Add-AuditLog -Action "Delete" -Entity "Rough Estimate" -Details "Bill No $($b.BillNo) - $($b.CustomerText)"
            Load-Grid
        }
    })
    $btnRefresh.Add_Click({ $script:AllCustomers = Get-AllCustomers; Load-Grid })
    # 2026-09-09 (session 12): double-click a row to open it directly in Edit,
    # so a bill found via the new search box can be opened in one action.
    $grid.Add_CellDoubleClick({
        param($s, $e)
        if ($e.RowIndex -ge 0) { $btnEdit.PerformClick() }
    })

    $btnView.Add_Click({
        $b = Get-SelectedBill
        if (-not $b) { [System.Windows.Forms.MessageBox]::Show("Pehle ek bill select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        $btype = "$($b.BillType)".Trim(); if ($btype -eq "") { $btype = "Rough Estimate" }
        $lines = "Bill No: $($b.BillNo)`nType: $btype`nDate: $($b.BillDate)`nCustomer: $($b.CustomerText)`nMobile: $($b.Mobile)`nAddress: $($b.Address)`n`nItems:`n"
        foreach ($it in $b.Items) { $lines += "  $($it.Description) x $($it.Qty) @ Rs.$($it.Rate) = Rs.$($it.Amount)`n" }
        $gstPctVal = 0.0; [double]::TryParse("$($b.GstPct)", [ref]$gstPctVal) | Out-Null
        $taxLine = if ($gstPctVal -gt 0) { "Tax %: $($b.GstPct)   Tax Amt: Rs.$($b.GstAmt)" } else { "Tax Amt: Rs.$($b.GstAmt)" }
        $lines += "`nTotal: Rs.$($b.Total)`n$taxLine`nNet Amount: Rs.$($b.NetAmount)"
        [System.Windows.Forms.MessageBox]::Show($lines, "Bill Details - $($b.BillNo)", "OK", "Information") | Out-Null
    })
    $btnResend.Add_Click({
        $b = Get-SelectedBill
        if (-not $b) { [System.Windows.Forms.MessageBox]::Show("Pehle ek bill select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        $partyName = ($b.CustomerText -split ' - ')[1]
        $itemLines = ""
        foreach ($it in $b.Items) { $itemLines += "$($it.Description) x $($it.Qty) = Rs. $($it.Amount)`n" }
        $btype = "$($b.BillType)".Trim(); if ($btype -eq "") { $btype = "Rough Estimate" }
        $msg = "Vani, Meerut - DASH X`n$btype`nBill No: $($b.BillNo)`nDate: $($b.BillDate)`nParty: $partyName`n`n$itemLines`nNet Amount: Rs. $($b.NetAmount)`n`nThank you for your business!"
        $imgPath = Get-BillImage $b
        $custCode = ($b.CustomerText -split ' - ')[0].Trim()
        $liveCust = $script:AllCustomers | Where-Object { "$($_.Code)".Trim() -eq $custCode } | Select-Object -First 1
        $mobToUse = if ($liveCust -and "$($liveCust.Mobile)".Trim() -ne "") { $liveCust.Mobile } else { $b.Mobile }
        Send-WhatsAppMessage -Mobile $mobToUse -Message $msg -ImagePath $imgPath
        if ($script:LastWhatsAppSendOk) {
            $allBills = @(Read-JsonArray $BillsFile)
            foreach ($bb in $allBills) {
                if ("$($bb.BillNo)" -eq "$($b.BillNo)") { $bb | Add-Member -NotePropertyName WhatsAppSent -NotePropertyValue $true -Force }
            }
            Save-JsonArray $BillsFile $allBills
            Load-Grid
        }
    })
    $btnPrint.Add_Click({
        $b = Get-SelectedBill
        if (-not $b) { [System.Windows.Forms.MessageBox]::Show("Pehle ek bill select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        Show-BillPrintPreview $b
    })
    $btnClose.Add_Click({ $form.Close() })

    $lblShortcuts2 = New-Object System.Windows.Forms.Label
    $lblShortcuts2.Text = "F2 = New    F5 = Print"
    $lblShortcuts2.Font = New-Object System.Drawing.Font("Tahoma", 8, [System.Drawing.FontStyle]::Italic)
    $lblShortcuts2.ForeColor = [System.Drawing.Color]::DimGray
    $lblShortcuts2.AutoSize = $true
    $lblShortcuts2.Location = New-Object System.Drawing.Point(462, 512)
    $lblShortcuts2.Anchor = "Bottom, Left"
    $form.Controls.Add($lblShortcuts2) | Out-Null

    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'F2') { $btnNew.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'F5') { $btnPrint.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
    })

    Load-Grid
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  ROUGH ESTIMATE REGISTER FORM
#  Reports menu - shows every Rough Estimate bill (oldest first) with a
#  grand total, and prints the whole list as one register (see
#  Show-RegisterPrintPreview above).
# ============================================================================
function Show-RoughEstimateRegisterForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Rough Estimate Register"
    $form.Size = New-Object System.Drawing.Size(900, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "ROUGH ESTIMATE REGISTER" 884))

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 50); $grid.Size = New-Object System.Drawing.Size(860, 400)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("SrNo", "Sr.No") | Out-Null
    $grid.Columns.Add("BillNo", "Bill No") | Out-Null
    $grid.Columns.Add("BillDate", "Date") | Out-Null
    $grid.Columns.Add("Customer", "Customer") | Out-Null
    $grid.Columns.Add("City", "City") | Out-Null
    $grid.Columns.Add("NetAmount", "Amount") | Out-Null
    $grid.Columns["SrNo"].Width = 55; $grid.Columns["BillNo"].Width = 80; $grid.Columns["BillDate"].Width = 90
    $grid.Columns["Customer"].Width = 250; $grid.Columns["City"].Width = 130; $grid.Columns["NetAmount"].Width = 130
    $grid.Columns["NetAmount"].DefaultCellStyle.Alignment = "MiddleRight"
    $form.Controls.Add($grid)

    $script:RegisterBills = @()
    function Load-Register {
        $grid.Rows.Clear()
        $script:RegisterBills = @(Read-JsonArray $BillsFile) | Sort-Object { [int]($_.BillNo -replace '[^0-9]','') }
        $sr = 1
        $grandTotal = 0.0
        foreach ($b in $script:RegisterBills) {
            $parts = "$($b.CustomerText)" -split ' - '
            $custDesc = if ($parts.Count -gt 1) { $parts[1] } else { $parts[0] }
            $grid.Rows.Add($sr, $b.BillNo, $b.BillDate, $custDesc, $b.City, $b.NetAmount) | Out-Null
            $v = 0.0; [double]::TryParse(("$($b.NetAmount)" -replace ',', ''), [ref]$v) | Out-Null
            $grandTotal += $v
            $sr++
        }
        $lblCount.Text = "Total Bills: $($grid.Rows.Count)      Grand Total: Rs. $($grandTotal.ToString('N2'))"
    }

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Text = "Total Bills: 0"
    $lblCount.Font = $FontBold
    $lblCount.Location = New-Object System.Drawing.Point(12, 458); $lblCount.AutoSize = $true
    $lblCount.Anchor = "Bottom, Left"

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(12, 488); $btnRefresh.Anchor = "Bottom, Left"
    $btnPrint = New-Object System.Windows.Forms.Button
    $btnPrint.Text = "Print Register"; $btnPrint.Font = $FontBold; $btnPrint.Size = New-Object System.Drawing.Size(140, 34)
    $btnPrint.Location = New-Object System.Drawing.Point(112, 488); $btnPrint.BackColor = [System.Drawing.Color]::FromArgb(210, 220, 240)
    $btnPrint.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(782, 488); $btnClose.Anchor = "Bottom, Right"

    $form.Controls.Add($lblCount) | Out-Null
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnPrint) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $btnRefresh.Add_Click({ Load-Register })
    $btnPrint.Add_Click({
        if ($script:RegisterBills.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Koi Rough Estimate bill nahi mila.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        Show-RegisterPrintPreview $script:RegisterBills
    })
    $btnClose.Add_Click({ $form.Close() })

    Load-Register
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  PARTY LEDGER / KHATA FORM
#  Pick a customer -> full statement (Opening Bal, every Rough Estimate/Sale,
#  every Cash/Bank receipt, running Dr/Cr balance) - same layout as the old
#  "Ledger Account" report, plus one-click WhatsApp send of the statement.
# ============================================================================
function Show-LedgerForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Party Ledger (Khata)"
    $form.Size = New-Object System.Drawing.Size(920, 620)
    $form.MinimumSize = New-Object System.Drawing.Size(920, 620)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "PARTY LEDGER (KHATA)" 904))

    $lblCust = New-Object System.Windows.Forms.Label
    $lblCust.Text = "Party:"; $lblCust.Location = New-Object System.Drawing.Point(15, 52); $lblCust.AutoSize = $true
    $cboCustomer = New-Object System.Windows.Forms.ComboBox
    $cboCustomer.Location = New-Object System.Drawing.Point(65, 49); $cboCustomer.Size = New-Object System.Drawing.Size(420, 22)
    $cboCustomer.DropDownStyle = "DropDown"; $cboCustomer.AutoCompleteMode = "SuggestAppend"; $cboCustomer.AutoCompleteSource = "ListItems"
    $script:AllCustomers = Get-AllCustomers
    $custList = New-Object System.Collections.ArrayList
    foreach ($c in $script:AllCustomers) { [void]$custList.Add("$($c.Code) - $($c.Name)") }
    $cboCustomer.Items.AddRange($custList.ToArray())
    Enable-ComboBoxContainsSearch -Combo $cboCustomer -GetAllItems { $custList.ToArray() }
    $btnShow = New-Object System.Windows.Forms.Button
    $btnShow.Text = "Show Khata"; $btnShow.Font = $FontBold; $btnShow.Size = New-Object System.Drawing.Size(110, 26)
    $btnShow.Location = New-Object System.Drawing.Point(495, 48)
    $lblBalance = New-Object System.Windows.Forms.Label
    $lblBalance.Text = ""; $lblBalance.Font = $FontTitle; $lblBalance.ForeColor = $ColorVfpBlue
    $lblBalance.AutoSize = $true; $lblBalance.Location = New-Object System.Drawing.Point(620, 48)
    $form.Controls.Add($lblCust) | Out-Null
    $form.Controls.Add($cboCustomer) | Out-Null
    $form.Controls.Add($btnShow) | Out-Null
    $form.Controls.Add($lblBalance) | Out-Null

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 85); $grid.Size = New-Object System.Drawing.Size(880, 430)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Font = New-Object System.Drawing.Font("Tahoma", 11)
    $grid.RowTemplate.Height = 26
    $grid.Columns.Add("Date", "Date") | Out-Null
    $grid.Columns.Add("VouNo", "Vou.No") | Out-Null
    $grid.Columns.Add("Particulars", "Particulars") | Out-Null
    $grid.Columns.Add("Debit", "Debit") | Out-Null
    $grid.Columns.Add("Credit", "Credit") | Out-Null
    $grid.Columns.Add("Balance", "Cl.Balance") | Out-Null
    $grid.Columns["Date"].Width = 90; $grid.Columns["VouNo"].Width = 90; $grid.Columns["Particulars"].Width = 320
    $grid.Columns["Debit"].Width = 110; $grid.Columns["Credit"].Width = 110; $grid.Columns["Balance"].Width = 140
    $grid.Columns["Debit"].DefaultCellStyle.Alignment = "MiddleRight"
    $grid.Columns["Credit"].DefaultCellStyle.Alignment = "MiddleRight"
    $grid.Columns["Balance"].DefaultCellStyle.Alignment = "MiddleRight"
    $form.Controls.Add($grid)

    $script:CurrentLedgerRows = @()
    function Load-Ledger {
        if ($cboCustomer.Text.Trim() -eq "") {
            [System.Windows.Forms.MessageBox]::Show("Pehle party select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        $code = ($cboCustomer.Text -split ' - ')[0].Trim()
        $rows = Get-CustomerLedger -CustCode $code
        $script:CurrentLedgerRows = $rows
        $grid.Rows.Clear()
        foreach ($r in $rows) {
            $grid.Rows.Add($r.Date, $r.VouNo, $r.Particulars, $r.Debit, $r.Credit, $r.Balance) | Out-Null
        }
        if ($rows.Count -gt 0) {
            $lblBalance.Text = "Balance: $($rows[$rows.Count-1].Balance)"
        } else {
            $lblBalance.Text = "Balance: 0.00"
        }
    }
    $btnShow.Add_Click({ Load-Ledger })
    $cboCustomer.Add_SelectedIndexChanged({ Load-Ledger })

    $btnWhatsApp = New-Object System.Windows.Forms.Button
    $btnWhatsApp.Text = "Send WhatsApp"; $btnWhatsApp.Font = $FontBold; $btnWhatsApp.Size = New-Object System.Drawing.Size(140, 34)
    $btnWhatsApp.Location = New-Object System.Drawing.Point(12, 528); $btnWhatsApp.BackColor = [System.Drawing.Color]::FromArgb(200, 230, 200)
    $btnWhatsApp.Anchor = "Bottom, Left"
    $btnPrint = New-Object System.Windows.Forms.Button
    $btnPrint.Text = "Print"; $btnPrint.Font = $FontBold; $btnPrint.Size = New-Object System.Drawing.Size(110, 34)
    $btnPrint.Location = New-Object System.Drawing.Point(162, 528); $btnPrint.BackColor = [System.Drawing.Color]::FromArgb(200, 215, 235)
    $btnPrint.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(802, 528)
    $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnWhatsApp) | Out-Null
    $form.Controls.Add($btnPrint) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $btnWhatsApp.Add_Click({
        Invoke-Safe {
            if ($cboCustomer.Text.Trim() -eq "" -or $script:CurrentLedgerRows.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("Pehle 'Show Khata' dabakar party ka khata dekhein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
            }
            $code = ($cboCustomer.Text -split ' - ')[0].Trim()
            $partyName = ($cboCustomer.Text -split ' - ')[1]
            $cust = $script:AllCustomers | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
            $lines = ""
            # last 15 entries only in the WhatsApp text - full detail stays on screen/print
            $recent = $script:CurrentLedgerRows | Select-Object -Skip ([Math]::Max(0, $script:CurrentLedgerRows.Count - 15))
            foreach ($r in $recent) {
                if ($r.VouNo -eq "") { $lines += "Opening: $($r.Balance)`n"; continue }
                $amt = if ($r.Debit -ne "") { "Dr $($r.Debit)" } else { "Cr $($r.Credit)" }
                $lines += "$($r.Date)  $($r.Particulars)  $amt`n"
            }
            $finalBal = $script:CurrentLedgerRows[$script:CurrentLedgerRows.Count - 1].Balance
            $msg = "Vani, Meerut - DASH X`nParty Ledger: $partyName`n`n$lines`nCurrent Balance: Rs. $finalBal`n`nKindly check and confirm."
            $mob = if ($cust) { $cust.Mobile } else { "" }
            $imgPath = Get-LedgerImage -PartyCode $code -PartyName $partyName -Rows $script:CurrentLedgerRows -Title "PARTY LEDGER STATEMENT"
            Send-WhatsAppMessage -Mobile $mob -Message $msg -ImagePath $imgPath
        }
    })
    $btnPrint.Add_Click({
        Invoke-Safe {
            if ($cboCustomer.Text.Trim() -eq "" -or $script:CurrentLedgerRows.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("Pehle 'Show Khata' dabakar party ka khata dekhein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
            }
            $code = ($cboCustomer.Text -split ' - ')[0].Trim()
            $partyName = ($cboCustomer.Text -split ' - ')[1]
            Show-LedgerPrintPreview -PartyCode $code -PartyName $partyName -Rows $script:CurrentLedgerRows
        }
    })
    $btnClose.Add_Click({ $form.Close() })

    $lblShortcuts3 = New-Object System.Windows.Forms.Label
    $lblShortcuts3.Text = "Enter = Show Khata    F5 = Print"
    $lblShortcuts3.Font = New-Object System.Drawing.Font("Tahoma", 8, [System.Drawing.FontStyle]::Italic)
    $lblShortcuts3.ForeColor = [System.Drawing.Color]::DimGray
    $lblShortcuts3.AutoSize = $true
    $lblShortcuts3.Location = New-Object System.Drawing.Point(500, 536)
    $lblShortcuts3.Anchor = "Bottom, Left"
    $form.Controls.Add($lblShortcuts3) | Out-Null

    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'F5') { $btnPrint.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'Return' -and $form.ActiveControl -eq $cboCustomer) {
            $btnShow.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true
        }
    })

    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  CUSTOMER STATEMENT (CUSTOM DATE RANGE)
#  "Is date se is date tak" wala hisab - party chuno, From/To date chuno,
#  Show Statement dabao. Balance hamesha sahi rehta hai kyunki purani sab
#  entries ka total "Opening Balance" mein carry-forward ho jaata hai.
# ============================================================================
function Show-CustomerStatementForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Customer Statement (Date Range)"
    $form.Size = New-Object System.Drawing.Size(940, 640)
    $form.MinimumSize = New-Object System.Drawing.Size(940, 640)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "CUSTOMER STATEMENT (DATE SE DATE TAK)" 924))

    $lblCust = New-Object System.Windows.Forms.Label
    $lblCust.Text = "Party:"; $lblCust.Location = New-Object System.Drawing.Point(15, 52); $lblCust.AutoSize = $true
    $cboCustomer = New-Object System.Windows.Forms.ComboBox
    $cboCustomer.Location = New-Object System.Drawing.Point(60, 49); $cboCustomer.Size = New-Object System.Drawing.Size(320, 22)
    $cboCustomer.DropDownStyle = "DropDown"; $cboCustomer.AutoCompleteMode = "SuggestAppend"; $cboCustomer.AutoCompleteSource = "ListItems"
    $script:AllCustomers = Get-AllCustomers
    $custList = New-Object System.Collections.ArrayList
    foreach ($c in $script:AllCustomers) { [void]$custList.Add("$($c.Code) - $($c.Name)") }
    $cboCustomer.Items.AddRange($custList.ToArray())
    Enable-ComboBoxContainsSearch -Combo $cboCustomer -GetAllItems { $custList.ToArray() }

    $lblFrom = New-Object System.Windows.Forms.Label
    $lblFrom.Text = "From:"; $lblFrom.Location = New-Object System.Drawing.Point(392, 52); $lblFrom.AutoSize = $true
    $dtpFrom = New-Object System.Windows.Forms.DateTimePicker
    $dtpFrom.Location = New-Object System.Drawing.Point(432, 48); $dtpFrom.Size = New-Object System.Drawing.Size(115, 22)
    $dtpFrom.Format = "Short"
    $dtpFrom.Value = Get-Date -Year (Get-Date).Year -Month 4 -Day 1
    if ((Get-Date).Month -lt 4) { $dtpFrom.Value = $dtpFrom.Value.AddYears(-1) }

    $lblTo = New-Object System.Windows.Forms.Label
    $lblTo.Text = "To:"; $lblTo.Location = New-Object System.Drawing.Point(558, 52); $lblTo.AutoSize = $true
    $dtpTo = New-Object System.Windows.Forms.DateTimePicker
    $dtpTo.Location = New-Object System.Drawing.Point(588, 48); $dtpTo.Size = New-Object System.Drawing.Size(115, 22)
    $dtpTo.Format = "Short"
    $dtpTo.Value = Get-Date

    $btnShow = New-Object System.Windows.Forms.Button
    $btnShow.Text = "Show Statement"; $btnShow.Font = $FontBold; $btnShow.Size = New-Object System.Drawing.Size(130, 26)
    $btnShow.Location = New-Object System.Drawing.Point(714, 48)

    $lblBalance = New-Object System.Windows.Forms.Label
    $lblBalance.Text = ""; $lblBalance.Font = $FontBold; $lblBalance.ForeColor = $ColorVfpBlue
    $lblBalance.AutoSize = $true; $lblBalance.Location = New-Object System.Drawing.Point(15, 80)

    $form.Controls.Add($lblCust) | Out-Null
    $form.Controls.Add($cboCustomer) | Out-Null
    $form.Controls.Add($lblFrom) | Out-Null
    $form.Controls.Add($dtpFrom) | Out-Null
    $form.Controls.Add($lblTo) | Out-Null
    $form.Controls.Add($dtpTo) | Out-Null
    $form.Controls.Add($btnShow) | Out-Null
    $form.Controls.Add($lblBalance) | Out-Null

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 108); $grid.Size = New-Object System.Drawing.Size(900, 420)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Font = New-Object System.Drawing.Font("Tahoma", 11)
    $grid.RowTemplate.Height = 26
    $grid.Columns.Add("Date", "Date") | Out-Null
    $grid.Columns.Add("VouNo", "Vou.No") | Out-Null
    $grid.Columns.Add("Particulars", "Particulars") | Out-Null
    $grid.Columns.Add("Debit", "Debit") | Out-Null
    $grid.Columns.Add("Credit", "Credit") | Out-Null
    $grid.Columns.Add("Balance", "Cl.Balance") | Out-Null
    $grid.Columns["Date"].Width = 90; $grid.Columns["VouNo"].Width = 90; $grid.Columns["Particulars"].Width = 340
    $grid.Columns["Debit"].Width = 110; $grid.Columns["Credit"].Width = 110; $grid.Columns["Balance"].Width = 140
    $grid.Columns["Debit"].DefaultCellStyle.Alignment = "MiddleRight"
    $grid.Columns["Credit"].DefaultCellStyle.Alignment = "MiddleRight"
    $grid.Columns["Balance"].DefaultCellStyle.Alignment = "MiddleRight"
    $form.Controls.Add($grid)

    $script:CurrentStatementRows = @()
    function Load-Statement {
        try {
            if ($cboCustomer.Text.Trim() -eq "") {
                [System.Windows.Forms.MessageBox]::Show("Pehle party select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
            }
            if ($dtpFrom.Value.Date -gt $dtpTo.Value.Date) {
                [System.Windows.Forms.MessageBox]::Show("From date, To date se pehle honi chahiye.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
            }
            $code = ($cboCustomer.Text -split ' - ')[0].Trim()
            $rows = Get-CustomerLedgerRange -CustCode $code -FromDate $dtpFrom.Value -ToDate $dtpTo.Value
            $script:CurrentStatementRows = $rows
            $grid.Rows.Clear()
            foreach ($r in $rows) {
                $grid.Rows.Add($r.Date, $r.VouNo, $r.Particulars, $r.Debit, $r.Credit, $r.Balance) | Out-Null
            }
            if ($rows.Count -gt 0) {
                $lblBalance.Text = "Closing Balance ($($dtpTo.Value.ToString('dd-MM-yyyy')) tak): $($rows[$rows.Count-1].Balance)"
            } else {
                $lblBalance.Text = "Is date range mein koi entry nahi mili."
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Statement dikhane mein error aaya:`n`n$($_.Exception.Message)`n`nLine: $($_.InvocationInfo.ScriptLineNumber)", "Nav Durga Sports - Error", "OK", "Error") | Out-Null
        }
    }
    $btnShow.Add_Click({ Load-Statement })

    $btnWhatsApp = New-Object System.Windows.Forms.Button
    $btnWhatsApp.Text = "Send WhatsApp"; $btnWhatsApp.Font = $FontBold; $btnWhatsApp.Size = New-Object System.Drawing.Size(140, 34)
    $btnWhatsApp.Location = New-Object System.Drawing.Point(12, 540); $btnWhatsApp.BackColor = [System.Drawing.Color]::FromArgb(200, 230, 200)
    $btnWhatsApp.Anchor = "Bottom, Left"
    $btnPrint = New-Object System.Windows.Forms.Button
    $btnPrint.Text = "Print"; $btnPrint.Font = $FontBold; $btnPrint.Size = New-Object System.Drawing.Size(110, 34)
    $btnPrint.Location = New-Object System.Drawing.Point(162, 540); $btnPrint.BackColor = [System.Drawing.Color]::FromArgb(200, 215, 235)
    $btnPrint.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(822, 540)
    $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnWhatsApp) | Out-Null
    $form.Controls.Add($btnPrint) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $btnWhatsApp.Add_Click({
        Invoke-Safe {
            if ($cboCustomer.Text.Trim() -eq "" -or $script:CurrentStatementRows.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("Pehle 'Show Statement' dabakar hisab dekhein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
            }
            $code = ($cboCustomer.Text -split ' - ')[0].Trim()
            $partyName = ($cboCustomer.Text -split ' - ')[1]
            $cust = $script:AllCustomers | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
            $lines = ""
            foreach ($r in $script:CurrentStatementRows) {
                if ($r.VouNo -eq "") { $lines += "$($r.Particulars): $($r.Balance)`n"; continue }
                $amt = if ($r.Debit -ne "") { "Dr $($r.Debit)" } else { "Cr $($r.Credit)" }
                $lines += "$($r.Date)  $($r.Particulars)  $amt`n"
            }
            $finalBal = $script:CurrentStatementRows[$script:CurrentStatementRows.Count - 1].Balance
            $msg = "Vani, Meerut - DASH X`nStatement: $partyName`n$($dtpFrom.Value.ToString('dd-MM-yyyy')) se $($dtpTo.Value.ToString('dd-MM-yyyy')) tak`n`n$lines`nClosing Balance: Rs. $finalBal`n`nKindly check and confirm."
            $mob = if ($cust) { $cust.Mobile } else { "" }
            $imgPath = Get-LedgerImage -PartyCode $code -PartyName $partyName -Rows $script:CurrentStatementRows -Title "CUSTOMER STATEMENT"
            Send-WhatsAppMessage -Mobile $mob -Message $msg -ImagePath $imgPath
        }
    })
    $btnPrint.Add_Click({
        Invoke-Safe {
            if ($cboCustomer.Text.Trim() -eq "" -or $script:CurrentStatementRows.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("Pehle 'Show Statement' dabakar hisab dekhein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
            }
            $code = ($cboCustomer.Text -split ' - ')[0].Trim()
            $partyName = ($cboCustomer.Text -split ' - ')[1]
            Show-LedgerPrintPreview -PartyCode $code -PartyName $partyName -Rows $script:CurrentStatementRows
        }
    })
    $btnClose.Add_Click({ $form.Close() })

    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'F5') { $btnPrint.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
    })

    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  PURCHASE VOUCHER ENTRY FORM
#  Pick supplier/account (same master as customers - ac_maste.dbf), add
#  items purchased (product/qty/rate/amount grid, same pattern as Sales
#  Bill Entry), a Narration line, and Save. Saved vouchers show up as a
#  Credit entry ("Purchase Voucher No.xxx") in that account's Party Ledger.
# ============================================================================
function Show-PurchaseVoucherForm {
    param($Existing = $null)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Purchase Voucher Entry"
    $form.Size = New-Object System.Drawing.Size(960, 620)
    $form.MinimumSize = New-Object System.Drawing.Size(960, 620)
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "Sizable"
    $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control
    $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "PURCHASE VOUCHER ENTRY" 944))

    $grpVou = New-Object System.Windows.Forms.GroupBox
    $grpVou.Text = "Voucher Details"; $grpVou.Font = $FontBold
    $grpVou.Location = New-Object System.Drawing.Point(12, 50); $grpVou.Size = New-Object System.Drawing.Size(910, 60)
    $lblVouNo = New-Object System.Windows.Forms.Label
    $lblVouNo.Text = "Voucher No:"; $lblVouNo.Location = New-Object System.Drawing.Point(15, 25); $lblVouNo.AutoSize = $true
    $txtVouNo = New-Object System.Windows.Forms.TextBox
    $txtVouNo.Location = New-Object System.Drawing.Point(105, 22); $txtVouNo.Size = New-Object System.Drawing.Size(90, 22)
    $txtVouNo.ReadOnly = $true; $txtVouNo.BackColor = [System.Drawing.Color]::LightYellow; $txtVouNo.Font = $FontBold
    $lblVouDate = New-Object System.Windows.Forms.Label
    $lblVouDate.Text = "Voucher Date:"; $lblVouDate.Location = New-Object System.Drawing.Point(220, 25); $lblVouDate.AutoSize = $true
    $dtpVouDate = New-Object System.Windows.Forms.DateTimePicker
    $dtpVouDate.Format = "Short"; $dtpVouDate.Location = New-Object System.Drawing.Point(310, 22); $dtpVouDate.Size = New-Object System.Drawing.Size(110, 22)
    $grpVou.Controls.Add($lblVouNo) | Out-Null
    $grpVou.Controls.Add($txtVouNo) | Out-Null
    $grpVou.Controls.Add($lblVouDate) | Out-Null
    $grpVou.Controls.Add($dtpVouDate) | Out-Null
    $form.Controls.Add($grpVou)

    $grpAcc = New-Object System.Windows.Forms.GroupBox
    $grpAcc.Text = "Account Details"; $grpAcc.Font = $FontBold
    $grpAcc.Location = New-Object System.Drawing.Point(12, 115); $grpAcc.Size = New-Object System.Drawing.Size(910, 95)
    $lblAcc = New-Object System.Windows.Forms.Label
    $lblAcc.Text = "Account:"; $lblAcc.Location = New-Object System.Drawing.Point(15, 28); $lblAcc.AutoSize = $true
    $cboAccount = New-Object System.Windows.Forms.ComboBox
    $cboAccount.Location = New-Object System.Drawing.Point(100, 25); $cboAccount.Size = New-Object System.Drawing.Size(360, 22)
    $cboAccount.DropDownStyle = "DropDown"; $cboAccount.AutoCompleteMode = "SuggestAppend"; $cboAccount.AutoCompleteSource = "ListItems"
    $script:AllCustomers = Get-AllCustomers
    $script:AllProducts = Get-AllProducts
    $accList = New-Object System.Collections.ArrayList
    foreach ($c in $script:AllCustomers) { [void]$accList.Add("$($c.Code) - $($c.Name)") }
    $cboAccount.Items.AddRange($accList.ToArray())
    Enable-ComboBoxContainsSearch -Combo $cboAccount -GetAllItems { $accList.ToArray() }
    $lblCity = New-Object System.Windows.Forms.Label
    $lblCity.Text = "City:"; $lblCity.Location = New-Object System.Drawing.Point(475, 28); $lblCity.AutoSize = $true
    $txtCity = New-Object System.Windows.Forms.TextBox
    $txtCity.Location = New-Object System.Drawing.Point(515, 25); $txtCity.Size = New-Object System.Drawing.Size(380, 22); $txtCity.ReadOnly = $true
    $lblNarr = New-Object System.Windows.Forms.Label
    $lblNarr.Text = "Narration:"; $lblNarr.Location = New-Object System.Drawing.Point(15, 58); $lblNarr.AutoSize = $true
    $txtNarr = New-Object System.Windows.Forms.TextBox
    $txtNarr.Location = New-Object System.Drawing.Point(100, 55); $txtNarr.Size = New-Object System.Drawing.Size(795, 22)
    $grpAcc.Controls.Add($lblAcc) | Out-Null
    $grpAcc.Controls.Add($cboAccount) | Out-Null
    $grpAcc.Controls.Add($lblCity) | Out-Null
    $grpAcc.Controls.Add($txtCity) | Out-Null
    $grpAcc.Controls.Add($lblNarr) | Out-Null
    $grpAcc.Controls.Add($txtNarr) | Out-Null
    $form.Controls.Add($grpAcc)

    function Update-AccountDetails {
        if ($cboAccount.Text.Trim() -eq "") { return }
        $code = ($cboAccount.Text -split ' - ')[0].Trim()
        $c = $script:AllCustomers | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
        if (-not $c) {
            $typed = $cboAccount.Text.Trim()
            $c = $script:AllCustomers | Where-Object { "$($_.Name)".Trim() -eq $typed } | Select-Object -First 1
        }
        if ($c) { $txtCity.Text = $c.City }
    }
    $cboAccount.Add_SelectedIndexChanged({ Update-AccountDetails })
    $cboAccount.Add_Leave({ Update-AccountDetails })

    $grpItems = New-Object System.Windows.Forms.GroupBox
    $grpItems.Text = "Items Purchased"; $grpItems.Font = $FontBold
    $grpItems.Location = New-Object System.Drawing.Point(12, 215); $grpItems.Size = New-Object System.Drawing.Size(910, 280)
    $grpItems.Anchor = "Top, Bottom, Left, Right"
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(10, 22); $grid.Size = New-Object System.Drawing.Size(890, 248)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.ReadOnly = $false
    $grid.AllowUserToAddRows = $true; $grid.AllowUserToDeleteRows = $true
    $colCode = New-Object System.Windows.Forms.DataGridViewComboBoxColumn
    $colCode.Name = "Code"; $colCode.HeaderText = "Item (select from list)"; $colCode.Width = 300
    $colCode.FlatStyle = "Standard"
    $colCode.DisplayStyle = "ComboBox"
    $productItems = New-Object System.Collections.Generic.List[string]
    foreach ($p in $script:AllProducts) { [void]$productItems.Add("$($p.Code) - $($p.Desc)") }
    [void]$colCode.Items.AddRange([string[]]$productItems.ToArray())
    $colDesc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colDesc.Name = "Description"; $colDesc.HeaderText = "Description"; $colDesc.Width = 220
    $colQty = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colQty.Name = "Qty"; $colQty.HeaderText = "Qty"; $colQty.Width = 70
    $colRate = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colRate.Name = "Rate"; $colRate.HeaderText = "Rate"; $colRate.Width = 90
    $colAmt = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colAmt.Name = "Amount"; $colAmt.HeaderText = "Amount"; $colAmt.Width = 100
    $colAmt.ReadOnly = $true; $colAmt.DefaultCellStyle.BackColor = $ColorGrid
    $grid.Columns.Add($colCode) | Out-Null
    $grid.Columns.Add($colDesc) | Out-Null
    $grid.Columns.Add($colQty) | Out-Null
    $grid.Columns.Add($colRate) | Out-Null
    $grid.Columns.Add($colAmt) | Out-Null
    $grpItems.Controls.Add($grid)
    $form.Controls.Add($grpItems)

    $grid.Add_CellClick({
        param($s, $e)
        if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 0) {
            # Guard against a fast double-click: CellClick fires once per click,
            # so a double-click calls this twice in quick succession. Calling
            # BeginEdit()/opening the dropdown a second time while the ComboBox
            # editing control is still being created can throw, and an
            # unhandled exception here freezes the whole app's message loop
            # (this was the "double-click/double-tap breaks everything" bug).
            # Skip if we're already editing this exact cell, and swallow any
            # error instead of letting it crash the UI thread.
            $already = $grid.IsCurrentCellInEditMode -and $grid.CurrentCell -and $grid.CurrentCell.RowIndex -eq $e.RowIndex -and $grid.CurrentCell.ColumnIndex -eq $e.ColumnIndex
            if ($already) { return }
            try {
                $grid.CurrentCell = $grid.Rows[$e.RowIndex].Cells[$e.ColumnIndex]
                $grid.BeginEdit($true)
                $openAction = [Action]{
                    try {
                        if ($grid.EditingControl -is [System.Windows.Forms.ComboBox] -and -not $grid.EditingControl.DroppedDown) {
                            $grid.EditingControl.DroppedDown = $true
                        }
                    } catch { }
                }
                $grid.BeginInvoke($openAction) | Out-Null
            } catch { }
        }
    })
    foreach ($c in $grid.Columns) { $c.SortMode = "NotSortable" }
    Enable-GridComboContainsSearch -Grid $grid -AllItems $productItems

    function Update-RowAmount($row) {
        $qty = 0.0; $rate = 0.0
        [double]::TryParse("$($row.Cells['Qty'].Value)", [ref]$qty) | Out-Null
        [double]::TryParse("$($row.Cells['Rate'].Value)", [ref]$rate) | Out-Null
        $row.Cells['Amount'].Value = [Math]::Round($qty * $rate, 2)
    }
    function Update-Total {
        $total = 0.0
        foreach ($row in $grid.Rows) {
            if (-not $row.IsNewRow) {
                $amt = 0.0
                [double]::TryParse("$($row.Cells['Amount'].Value)", [ref]$amt) | Out-Null
                $total += $amt
            }
        }
        $txtAmount.Text = [Math]::Round($total, 2).ToString("N2")
    }
    $grid.Add_CellEndEdit({
        param($s, $e)
        if ($e.RowIndex -lt 0) { return }
        $row = $grid.Rows[$e.RowIndex]
        if ($e.ColumnIndex -eq 0) {
            $selected = "$($row.Cells['Code'].Value)".Trim()
            $code = ($selected -split ' - ')[0].Trim()
            $p = $null
            if ($code -ne "") {
                $p = $script:AllProducts | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
            }
            if (-not $p -and $selected -ne "") {
                # User ne dropdown se select kiye bina seedha poora naam type kar
                # diya (ab jo type-search kaam karta hai, isliye ye zyada hoga) -
                # agar naam se EXACTLY ek hi product match kare to usko use kar lo,
                # warna galat/adhura naam bill mein jaane se rokne ke liye cell
                # khali kar do (Add-ProductRowToGrid jaisi hi safety soch).
                $found = @($script:AllProducts | Where-Object { "$($_.Desc)" -like "*$selected*" -or "$($_.Code)" -like "*$selected*" })
                if ($found.Count -eq 1) { $p = $found[0] }
            }
            if ($p) {
                $row.Cells['Code'].Value = "$($p.Code) - $($p.Desc)"
                $row.Cells['Description'].Value = $p.Desc
                $row.Cells['Rate'].Value = $p.Rate
                if ("$($row.Cells['Qty'].Value)".Trim() -eq "") { $row.Cells['Qty'].Value = 1 }
            } elseif ($selected -ne "") {
                $row.Cells['Code'].Value = ""
                $row.Cells['Description'].Value = ""
            }
        }
        Update-RowAmount $row
        Update-Total
    })

    $grpTotals = New-Object System.Windows.Forms.GroupBox
    $grpTotals.Text = "Total"; $grpTotals.Font = $FontBold
    $grpTotals.Location = New-Object System.Drawing.Point(12, 500); $grpTotals.Size = New-Object System.Drawing.Size(910, 55)
    $grpTotals.Anchor = "Bottom, Left, Right"
    $lblAmount = New-Object System.Windows.Forms.Label
    $lblAmount.Text = "Amount:"; $lblAmount.Font = $FontBold; $lblAmount.Location = New-Object System.Drawing.Point(15, 22); $lblAmount.AutoSize = $true
    $txtAmount = New-Object System.Windows.Forms.TextBox
    $txtAmount.Location = New-Object System.Drawing.Point(90, 19); $txtAmount.Size = New-Object System.Drawing.Size(130, 22)
    $txtAmount.ReadOnly = $true; $txtAmount.Font = $FontBold; $txtAmount.TextAlign = "Right"; $txtAmount.BackColor = [System.Drawing.Color]::LightYellow
    $grpTotals.Controls.Add($lblAmount) | Out-Null
    $grpTotals.Controls.Add($txtAmount) | Out-Null
    $form.Controls.Add($grpTotals)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save Voucher"; $btnSave.Font = $FontBold; $btnSave.Size = New-Object System.Drawing.Size(140, 34)
    $btnSave.Location = New-Object System.Drawing.Point(12, 565); $btnSave.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnSave.Anchor = "Bottom, Left"
    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = "New Voucher"; $btnNew.Font = $FontNormal; $btnNew.Size = New-Object System.Drawing.Size(130, 34)
    $btnNew.Location = New-Object System.Drawing.Point(162, 565)
    $btnNew.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(812, 565)
    $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnSave) | Out-Null
    $form.Controls.Add($btnNew) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $script:EditingVoucherNo = $null
    function Reset-Form {
        $txtVouNo.Text = Get-NextVoucherNo
        $dtpVouDate.Value = Get-Date
        $cboAccount.Text = ""; $txtCity.Text = ""; $txtNarr.Text = ""
        $grid.Rows.Clear()
        $txtAmount.Text = "0.00"
        $script:EditingVoucherNo = $null
    }
    function Get-CurrentVoucherObject {
        $items = @()
        foreach ($row in $grid.Rows) {
            if (-not $row.IsNewRow) {
                $selectedVal = "$($row.Cells['Code'].Value)".Trim()
                if ($selectedVal -ne "") {
                    $code = ($selectedVal -split ' - ')[0].Trim()
                    $items += [PSCustomObject]@{
                        Code = $code; Description = "$($row.Cells['Description'].Value)"
                        Qty = "$($row.Cells['Qty'].Value)"; Rate = "$($row.Cells['Rate'].Value)"; Amount = "$($row.Cells['Amount'].Value)"
                    }
                }
            }
        }
        return [PSCustomObject]@{
            VoucherNo = $txtVouNo.Text; VoucherDate = $dtpVouDate.Value.ToString("dd-MM-yyyy")
            AccountText = $cboAccount.Text; City = $txtCity.Text; Narration = $txtNarr.Text
            Items = $items; Amount = $txtAmount.Text
            SavedAt = (Get-Date).ToString("s")
        }
    }
    function Load-VoucherIntoForm($v) {
        $txtVouNo.Text = $v.VoucherNo
        try { $dtpVouDate.Value = [DateTime]::ParseExact($v.VoucherDate, "dd-MM-yyyy", $null) } catch {}
        $cboAccount.Text = $v.AccountText
        $txtCity.Text = $v.City
        $txtNarr.Text = $v.Narration
        $grid.Rows.Clear()
        foreach ($it in $v.Items) {
            $rowIdx = $grid.Rows.Add()
            $row = $grid.Rows[$rowIdx]
            $p = $script:AllProducts | Where-Object { "$($_.Code)".Trim() -eq "$($it.Code)".Trim() } | Select-Object -First 1
            $display = if ($p) { "$($p.Code) - $($p.Desc)" } else { "$($it.Code) - $($it.Description)" }
            $row.Cells['Code'].Value = $display
            $row.Cells['Description'].Value = $it.Description
            $row.Cells['Qty'].Value = $it.Qty
            $row.Cells['Rate'].Value = $it.Rate
            $row.Cells['Amount'].Value = $it.Amount
        }
        Update-Total
        $script:EditingVoucherNo = $v.VoucherNo
    }

    $btnSave.Add_Click({
        if ($cboAccount.Text.Trim() -eq "") {
            [System.Windows.Forms.MessageBox]::Show("Pehle account select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        $itemCount = ($grid.Rows | Where-Object { -not $_.IsNewRow -and "$($_.Cells['Code'].Value)".Trim() -ne "" }).Count
        if ($itemCount -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Kam se kam ek item add karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        $voucher = Get-CurrentVoucherObject
        $existing = @(Read-JsonArray $PurchaseVouchersFile)
        $auditAction = if ($script:EditingVoucherNo) { "Edit" } else { "Create" }
        if ($script:EditingVoucherNo) {
            $existing = @($existing | Where-Object { "$($_.VoucherNo)" -ne "$($script:EditingVoucherNo)" }) + $voucher
        } else {
            $existing = $existing + $voucher
        }
        Save-JsonArray $PurchaseVouchersFile $existing
        Add-AuditLog -Action $auditAction -Entity "Purchase Voucher" -Details "Voucher No $($voucher.VoucherNo) - $($voucher.AccountText) - Rs. $($voucher.Amount)"
        [System.Windows.Forms.MessageBox]::Show("Purchase Voucher No $($voucher.VoucherNo) save ho gaya.", "Nav Durga Sports", "OK", "Information") | Out-Null
        $form.Close()
    })
    $btnNew.Add_Click({ Reset-Form })
    $btnClose.Add_Click({ $form.Close() })

    $lblShortcuts4 = New-Object System.Windows.Forms.Label
    $lblShortcuts4.Text = "F2 = New Voucher    F3 = Save    Enter = Next Field"
    $lblShortcuts4.Font = New-Object System.Drawing.Font("Tahoma", 8, [System.Drawing.FontStyle]::Italic)
    $lblShortcuts4.ForeColor = [System.Drawing.Color]::DimGray
    $lblShortcuts4.AutoSize = $true
    $lblShortcuts4.Location = New-Object System.Drawing.Point(302, 577)
    $lblShortcuts4.Anchor = "Bottom, Left"
    $form.Controls.Add($lblShortcuts4) | Out-Null

    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'F2') { $btnNew.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'F3') { $btnSave.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'Return') {
            $ac = $form.ActiveControl
            if ($ac -and ($ac -is [System.Windows.Forms.TextBox] -or $ac -is [System.Windows.Forms.ComboBox] -or $ac -is [System.Windows.Forms.DateTimePicker]) -and -not ($ac -is [System.Windows.Forms.TextBox] -and $ac.ReadOnly)) {
                $form.SelectNextControl($ac, $true, $true, $true, $true) | Out-Null
                $e.Handled = $true; $e.SuppressKeyPress = $true
            }
        }
    })

    Reset-Form
    if ($Existing) { Load-VoucherIntoForm $Existing }
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  PURCHASE VOUCHER LIST FORM
#  Matches the old system's list-based Data Entry screens: shows every
#  purchase voucher saved in this software, with New/Edit/Delete/Refresh -
#  same idea as the old VFP screen's right-click menu, just as buttons.
# ============================================================================
function Show-PurchaseVoucherListForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Purchase Voucher List"
    $form.Size = New-Object System.Drawing.Size(950, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(950, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "PURCHASE VOUCHER LIST" 934))

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search:"; $lblSearch.Font = $FontBold; $lblSearch.AutoSize = $true
    $lblSearch.Location = New-Object System.Drawing.Point(12, 54)
    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(75, 51); $txtSearch.Size = New-Object System.Drawing.Size(300, 24)
    $btnClearSearch = New-Object System.Windows.Forms.Button
    $btnClearSearch.Text = "Clear"; $btnClearSearch.Font = $FontNormal; $btnClearSearch.Size = New-Object System.Drawing.Size(70, 26)
    $btnClearSearch.Location = New-Object System.Drawing.Point(385, 49)
    $form.Controls.Add($lblSearch) | Out-Null
    $form.Controls.Add($txtSearch) | Out-Null
    $form.Controls.Add($btnClearSearch) | Out-Null

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 88); $grid.Size = New-Object System.Drawing.Size(910, 362)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("VoucherNo", "Voucher No") | Out-Null
    $grid.Columns.Add("VoucherDate", "Voucher Date") | Out-Null
    $grid.Columns.Add("AccCode", "Account Code") | Out-Null
    $grid.Columns.Add("AccDesc", "Account Description") | Out-Null
    $grid.Columns.Add("AccCity", "Account City") | Out-Null
    $grid.Columns.Add("Narration", "Narration") | Out-Null
    $grid.Columns.Add("Amount", "Amount") | Out-Null
    $grid.Columns["VoucherNo"].Width = 90; $grid.Columns["VoucherDate"].Width = 100; $grid.Columns["AccCode"].Width = 90
    $grid.Columns["AccDesc"].Width = 220; $grid.Columns["AccCity"].Width = 120; $grid.Columns["Narration"].Width = 180; $grid.Columns["Amount"].Width = 100
    $grid.Columns["Amount"].DefaultCellStyle.Alignment = "MiddleRight"
    $form.Controls.Add($grid)

    $script:PurchaseVoucherData = @()
    function Load-Grid {
        $grid.Rows.Clear()
        $all = @(Read-JsonArray $PurchaseVouchersFile) | Sort-Object { [int]($_.VoucherNo -replace '[^0-9]','') } -Descending
        $q = $txtSearch.Text.Trim()
        $script:PurchaseVoucherData = if ($q -eq "") { $all } else {
            $all | Where-Object { "$($_.AccountText)" -like "*$q*" -or "$($_.Narration)" -like "*$q*" -or "$($_.VoucherNo)" -like "*$q*" -or "$($_.City)" -like "*$q*" }
        }
        foreach ($v in $script:PurchaseVoucherData) {
            $parts = "$($v.AccountText)" -split ' - '
            $accCode = $parts[0]
            $accDesc = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            $grid.Rows.Add($v.VoucherNo, $v.VoucherDate, $accCode, $accDesc, $v.City, $v.Narration, $v.Amount) | Out-Null
        }
        $lblCount.Text = "Record(s): $($grid.Rows.Count)"
    }

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Text = "Record(s): 0"
    $lblCount.Location = New-Object System.Drawing.Point(12, 458); $lblCount.AutoSize = $true
    $lblCount.Anchor = "Bottom, Left"

    function Get-SelectedVoucher {
        if ($grid.SelectedRows.Count -eq 0) { return $null }
        $vno = $grid.SelectedRows[0].Cells["VoucherNo"].Value
        return $script:PurchaseVoucherData | Where-Object { "$($_.VoucherNo)" -eq "$vno" } | Select-Object -First 1
    }

    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = "New Purchase Voucher"; $btnNew.Font = $FontBold; $btnNew.Size = New-Object System.Drawing.Size(170, 34)
    $btnNew.Location = New-Object System.Drawing.Point(12, 480); $btnNew.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnNew.Anchor = "Bottom, Left"
    $btnEdit = New-Object System.Windows.Forms.Button
    $btnEdit.Text = "Edit"; $btnEdit.Font = $FontBold; $btnEdit.Size = New-Object System.Drawing.Size(90, 34)
    $btnEdit.Location = New-Object System.Drawing.Point(192, 480)
    $btnEdit.Anchor = "Bottom, Left"
    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete"; $btnDelete.Font = $FontBold; $btnDelete.Size = New-Object System.Drawing.Size(90, 34)
    $btnDelete.Location = New-Object System.Drawing.Point(292, 480); $btnDelete.BackColor = [System.Drawing.Color]::FromArgb(240, 210, 210)
    $btnDelete.Anchor = "Bottom, Left"
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(392, 480)
    $btnRefresh.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(832, 480)
    $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($lblCount) | Out-Null
    $form.Controls.Add($btnNew) | Out-Null
    $form.Controls.Add($btnEdit) | Out-Null
    $form.Controls.Add($btnDelete) | Out-Null
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $txtSearch.Add_TextChanged({ Load-Grid })
    $btnClearSearch.Add_Click({ $txtSearch.Text = ""; Load-Grid })
    $btnNew.Add_Click({ Invoke-Safe { Show-PurchaseVoucherForm }; Load-Grid })
    $btnEdit.Add_Click({
        $v = Get-SelectedVoucher
        if (-not $v) { [System.Windows.Forms.MessageBox]::Show("Pehle ek voucher select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        Invoke-Safe { Show-PurchaseVoucherForm -Existing $v }
        Load-Grid
    })
    $btnDelete.Add_Click({
        $v = Get-SelectedVoucher
        if (-not $v) { [System.Windows.Forms.MessageBox]::Show("Pehle ek voucher select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Voucher No $($v.VoucherNo) delete karein?", "Nav Durga Sports", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            $remaining = @(Read-JsonArray $PurchaseVouchersFile) | Where-Object { "$($_.VoucherNo)" -ne "$($v.VoucherNo)" }
            Save-JsonArray $PurchaseVouchersFile $remaining
            Add-AuditLog -Action "Delete" -Entity "Purchase Voucher" -Details "Voucher No $($v.VoucherNo) - $($v.AccountText)"
            Load-Grid
        }
    })
    $btnRefresh.Add_Click({ Load-Grid })
    $btnClose.Add_Click({ $form.Close() })

    Load-Grid
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  SIMPLE MASTER SCREEN (Group / Unit / State / GST Master)
#  2026-09-11 (session 15): all four are a plain Code + Name list with
#  Add New / Delete - one shared, parameterised screen instead of four
#  near-identical copies, to keep this addition small and low-risk.
# ============================================================================
function Show-SimpleMasterForm {
    param([string]$Title, [string]$DataFile, [string]$ItemLabel)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - $Title"
    $form.Size = New-Object System.Drawing.Size(560, 520)
    $form.MinimumSize = New-Object System.Drawing.Size(560, 520)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner $Title.ToUpper() 544))

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 50); $grid.Size = New-Object System.Drawing.Size(520, 360)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Code", "Code") | Out-Null
    $grid.Columns.Add("Name", $ItemLabel) | Out-Null
    $grid.Columns["Code"].Width = 100; $grid.Columns["Name"].Width = 380
    $form.Controls.Add($grid)

    function Refresh-Grid {
        $grid.Rows.Clear()
        foreach ($item in (Read-JsonArray $DataFile)) {
            $grid.Rows.Add($item.Code, $item.Name) | Out-Null
        }
        $lblCount.Text = "Total: $($grid.Rows.Count)"
    }

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(12, 418); $lblCount.AutoSize = $true; $lblCount.Font = $FontNormal
    $lblCount.Anchor = "Bottom, Left"

    $btnAdd = New-Object System.Windows.Forms.Button
    $btnAdd.Text = "Add New"; $btnAdd.Font = $FontBold; $btnAdd.Size = New-Object System.Drawing.Size(120, 34)
    $btnAdd.Location = New-Object System.Drawing.Point(12, 440); $btnAdd.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnAdd.Anchor = "Bottom, Left"
    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete"; $btnDelete.Font = $FontBold; $btnDelete.Size = New-Object System.Drawing.Size(90, 34)
    $btnDelete.Location = New-Object System.Drawing.Point(142, 440); $btnDelete.BackColor = [System.Drawing.Color]::FromArgb(240, 210, 210)
    $btnDelete.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(442, 440)
    $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($lblCount) | Out-Null
    $form.Controls.Add($btnAdd) | Out-Null
    $form.Controls.Add($btnDelete) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $btnAdd.Add_Click({
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "Add New $ItemLabel"; $dlg.Size = New-Object System.Drawing.Size(380, 160)
        $dlg.StartPosition = "CenterParent"; $dlg.FormBorderStyle = "FixedDialog"; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
        $dlg.Font = $FontNormal
        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text = "$($ItemLabel):"; $lbl.Location = New-Object System.Drawing.Point(15, 22); $lbl.AutoSize = $true
        $tb = New-Object System.Windows.Forms.TextBox
        $tb.Location = New-Object System.Drawing.Point(120, 19); $tb.Size = New-Object System.Drawing.Size(230, 22)
        $dlg.Controls.Add($lbl) | Out-Null; $dlg.Controls.Add($tb) | Out-Null
        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = "Save"; $btnOk.Font = $FontBold; $btnOk.Location = New-Object System.Drawing.Point(120, 70); $btnOk.Size = New-Object System.Drawing.Size(100, 32)
        $btnCancel = New-Object System.Windows.Forms.Button
        $btnCancel.Text = "Cancel"; $btnCancel.Location = New-Object System.Drawing.Point(230, 70); $btnCancel.Size = New-Object System.Drawing.Size(100, 32)
        $dlg.Controls.Add($btnOk) | Out-Null
        $dlg.Controls.Add($btnCancel) | Out-Null
        $btnOk.Add_Click({
            try {
                if ($tb.Text.Trim() -eq "") {
                    [System.Windows.Forms.MessageBox]::Show("$ItemLabel dalna zaroori hai.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
                }
                $newCode = Get-NextNewCode -Prefix "M" -JsonFile $DataFile
                $obj = [PSCustomObject]@{ Code = $newCode; Name = $tb.Text.Trim() }
                $existingRows = @(Read-JsonArray $DataFile) + $obj
                Save-JsonArray $DataFile $existingRows
                Add-AuditLog -Action "Create" -Entity $Title -Details "$($obj.Code) - $($obj.Name)"
                $dlg.Tag = "saved"
                $dlg.Close()
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Save karte waqt error:`n$($_.Exception.Message)", "Nav Durga Sports - Error", "OK", "Error") | Out-Null
            }
        }.GetNewClosure())
        $btnCancel.Add_Click({ $dlg.Close() })
        $dlg.ShowDialog($form) | Out-Null
        if ($dlg.Tag -eq "saved") { Refresh-Grid }
    }.GetNewClosure())

    $btnDelete.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) { [System.Windows.Forms.MessageBox]::Show("Pehle ek record select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        $selCode = $grid.SelectedRows[0].Cells["Code"].Value
        $confirm = [System.Windows.Forms.MessageBox]::Show("$selCode delete karein?", "Nav Durga Sports", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            $remaining = @(Read-JsonArray $DataFile) | Where-Object { "$($_.Code)" -ne "$selCode" }
            Save-JsonArray $DataFile $remaining
            Add-AuditLog -Action "Delete" -Entity $Title -Details "$selCode"
            Refresh-Grid
        }
    }.GetNewClosure())
    $btnClose.Add_Click({ $form.Close() })

    Refresh-Grid
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  PRODUCT LIST (Lists -> "Product List")
#  Read-only report of every product (old DBF + new) - Code/Description/
#  Unit/Rate. No new data model, just a clean view of Get-AllProducts.
# ============================================================================
function Show-ProductListReportForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Product List"
    $form.Size = New-Object System.Drawing.Size(700, 520)
    $form.MinimumSize = New-Object System.Drawing.Size(700, 520)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "PRODUCT LIST" 684))

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search:"; $lblSearch.Font = $FontBold; $lblSearch.AutoSize = $true
    $lblSearch.Location = New-Object System.Drawing.Point(12, 54)
    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(75, 51); $txtSearch.Size = New-Object System.Drawing.Size(300, 24)
    $btnClearSearch = New-Object System.Windows.Forms.Button
    $btnClearSearch.Text = "Clear"; $btnClearSearch.Font = $FontNormal; $btnClearSearch.Size = New-Object System.Drawing.Size(70, 26)
    $btnClearSearch.Location = New-Object System.Drawing.Point(385, 49)
    $form.Controls.Add($lblSearch) | Out-Null
    $form.Controls.Add($txtSearch) | Out-Null
    $form.Controls.Add($btnClearSearch) | Out-Null

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 88); $grid.Size = New-Object System.Drawing.Size(660, 342)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Code", "Product Code") | Out-Null
    $grid.Columns.Add("Desc", "Product Description") | Out-Null
    $grid.Columns.Add("Unit", "Unit") | Out-Null
    $grid.Columns.Add("Rate", "Sale Rate") | Out-Null
    $grid.Columns["Code"].Width = 90; $grid.Columns["Desc"].Width = 340; $grid.Columns["Unit"].Width = 80; $grid.Columns["Rate"].Width = 100
    $form.Controls.Add($grid)

    function Refresh-Grid {
        $grid.Rows.Clear()
        $q = $txtSearch.Text.Trim()
        $all = (Get-AllProducts) | Sort-Object Desc
        $rows = if ($q -eq "") { $all } else { $all | Where-Object { "$($_.Code)" -like "*$q*" -or "$($_.Desc)" -like "*$q*" } }
        foreach ($p in $rows) {
            $grid.Rows.Add($p.Code, $p.Desc, $p.Unit, $p.Rate) | Out-Null
        }
        $lblCount.Text = "Total Products: $($grid.Rows.Count)"
    }
    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(12, 438); $lblCount.AutoSize = $true; $lblCount.Font = $FontNormal
    $lblCount.Anchor = "Bottom, Left"
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(12, 460); $btnRefresh.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(582, 460); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($lblCount) | Out-Null
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null
    $btnRefresh.Add_Click({ Refresh-Grid })
    $btnClose.Add_Click({ $form.Close() })
    $txtSearch.Add_TextChanged({ Refresh-Grid })
    $btnClearSearch.Add_Click({ $txtSearch.Text = ""; Refresh-Grid })

    Refresh-Grid
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  CASH RECEIPT VOUCHER (Data Entry -> "Cash Recd. Voucher")
#  Money RECEIVED from a party -> Credit entry in their ledger (reduces what
#  they owe), same idea as the old cashrecd.dbf receipts. Simplified version
#  of Purchase Voucher Entry: no items grid, just Account + Amount + Narration.
# ============================================================================
function Show-CashReceiptVoucherForm {
    param($Existing = $null)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Cash Receipt Voucher Entry"
    $form.Size = New-Object System.Drawing.Size(760, 400)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 400)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "CASH RECEIPT VOUCHER" 744))

    $grpVou = New-Object System.Windows.Forms.GroupBox
    $grpVou.Text = "Voucher Details"; $grpVou.Font = $FontBold
    $grpVou.Location = New-Object System.Drawing.Point(12, 50); $grpVou.Size = New-Object System.Drawing.Size(720, 60)
    $lblVouNo = New-Object System.Windows.Forms.Label
    $lblVouNo.Text = "Voucher No:"; $lblVouNo.Location = New-Object System.Drawing.Point(15, 25); $lblVouNo.AutoSize = $true
    $txtVouNo = New-Object System.Windows.Forms.TextBox
    $txtVouNo.Location = New-Object System.Drawing.Point(105, 22); $txtVouNo.Size = New-Object System.Drawing.Size(90, 22)
    $txtVouNo.ReadOnly = $true; $txtVouNo.BackColor = [System.Drawing.Color]::LightYellow; $txtVouNo.Font = $FontBold
    $lblVouDate = New-Object System.Windows.Forms.Label
    $lblVouDate.Text = "Voucher Date:"; $lblVouDate.Location = New-Object System.Drawing.Point(220, 25); $lblVouDate.AutoSize = $true
    $dtpVouDate = New-Object System.Windows.Forms.DateTimePicker
    $dtpVouDate.Format = "Short"; $dtpVouDate.Location = New-Object System.Drawing.Point(310, 22); $dtpVouDate.Size = New-Object System.Drawing.Size(110, 22)
    $grpVou.Controls.Add($lblVouNo) | Out-Null
    $grpVou.Controls.Add($txtVouNo) | Out-Null
    $grpVou.Controls.Add($lblVouDate) | Out-Null
    $grpVou.Controls.Add($dtpVouDate) | Out-Null
    $form.Controls.Add($grpVou)

    $grpAcc = New-Object System.Windows.Forms.GroupBox
    $grpAcc.Text = "Received From"; $grpAcc.Font = $FontBold
    $grpAcc.Location = New-Object System.Drawing.Point(12, 115); $grpAcc.Size = New-Object System.Drawing.Size(720, 130)
    $lblAcc = New-Object System.Windows.Forms.Label
    $lblAcc.Text = "Account:"; $lblAcc.Location = New-Object System.Drawing.Point(15, 28); $lblAcc.AutoSize = $true
    $cboAccount = New-Object System.Windows.Forms.ComboBox
    $cboAccount.Location = New-Object System.Drawing.Point(100, 25); $cboAccount.Size = New-Object System.Drawing.Size(360, 22)
    $cboAccount.DropDownStyle = "DropDown"
    $script:AllCustomers = Get-AllCustomers
    $accList = New-Object System.Collections.ArrayList
    foreach ($c in $script:AllCustomers) { [void]$accList.Add("$($c.Code) - $($c.Name)") }
    $cboAccount.Items.AddRange($accList.ToArray())
    Enable-ComboBoxContainsSearch -Combo $cboAccount -GetAllItems { $accList.ToArray() }
    $lblCity = New-Object System.Windows.Forms.Label
    $lblCity.Text = "City:"; $lblCity.Location = New-Object System.Drawing.Point(475, 28); $lblCity.AutoSize = $true
    $txtCity = New-Object System.Windows.Forms.TextBox
    $txtCity.Location = New-Object System.Drawing.Point(515, 25); $txtCity.Size = New-Object System.Drawing.Size(190, 22); $txtCity.ReadOnly = $true
    $lblAmount = New-Object System.Windows.Forms.Label
    $lblAmount.Text = "Amount:"; $lblAmount.Font = $FontBold; $lblAmount.Location = New-Object System.Drawing.Point(15, 58); $lblAmount.AutoSize = $true
    $txtAmount = New-Object System.Windows.Forms.TextBox
    $txtAmount.Location = New-Object System.Drawing.Point(100, 55); $txtAmount.Size = New-Object System.Drawing.Size(130, 22); $txtAmount.Font = $FontBold; $txtAmount.TextAlign = "Right"
    $lblNarr = New-Object System.Windows.Forms.Label
    $lblNarr.Text = "Narration:"; $lblNarr.Location = New-Object System.Drawing.Point(15, 90); $lblNarr.AutoSize = $true
    $txtNarr = New-Object System.Windows.Forms.TextBox
    $txtNarr.Location = New-Object System.Drawing.Point(100, 87); $txtNarr.Size = New-Object System.Drawing.Size(605, 22)
    $grpAcc.Controls.Add($lblAcc) | Out-Null
    $grpAcc.Controls.Add($cboAccount) | Out-Null
    $grpAcc.Controls.Add($lblCity) | Out-Null
    $grpAcc.Controls.Add($txtCity) | Out-Null
    $grpAcc.Controls.Add($lblAmount) | Out-Null
    $grpAcc.Controls.Add($txtAmount) | Out-Null
    $grpAcc.Controls.Add($lblNarr) | Out-Null
    $grpAcc.Controls.Add($txtNarr) | Out-Null
    $form.Controls.Add($grpAcc)

    function Update-AccountDetails {
        if ($cboAccount.Text.Trim() -eq "") { return }
        $code = ($cboAccount.Text -split ' - ')[0].Trim()
        $c = $script:AllCustomers | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
        if (-not $c) {
            $typed = $cboAccount.Text.Trim()
            $c = $script:AllCustomers | Where-Object { "$($_.Name)".Trim() -eq $typed } | Select-Object -First 1
        }
        if ($c) { $txtCity.Text = $c.City }
    }
    $cboAccount.Add_SelectedIndexChanged({ Update-AccountDetails })
    $cboAccount.Add_Leave({ Update-AccountDetails })

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save Voucher"; $btnSave.Font = $FontBold; $btnSave.Size = New-Object System.Drawing.Size(140, 34)
    $btnSave.Location = New-Object System.Drawing.Point(12, 300); $btnSave.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnSave.Anchor = "Bottom, Left"
    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = "New Voucher"; $btnNew.Font = $FontNormal; $btnNew.Size = New-Object System.Drawing.Size(130, 34)
    $btnNew.Location = New-Object System.Drawing.Point(162, 300); $btnNew.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(642, 300); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnSave) | Out-Null
    $form.Controls.Add($btnNew) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $script:EditingCRVoucherNo = $null
    function Reset-Form {
        $txtVouNo.Text = Get-NextCashReceiptNo
        $dtpVouDate.Value = Get-Date
        $cboAccount.Text = ""; $txtCity.Text = ""; $txtNarr.Text = ""; $txtAmount.Text = "0.00"
        $script:EditingCRVoucherNo = $null
    }
    function Get-CurrentVoucherObject {
        return [PSCustomObject]@{
            VoucherNo = $txtVouNo.Text; VoucherDate = $dtpVouDate.Value.ToString("dd-MM-yyyy")
            AccountText = $cboAccount.Text; City = $txtCity.Text; Narration = $txtNarr.Text
            Amount = $txtAmount.Text; SavedAt = (Get-Date).ToString("s")
        }
    }
    function Load-VoucherIntoForm($v) {
        $txtVouNo.Text = $v.VoucherNo
        try { $dtpVouDate.Value = [DateTime]::ParseExact($v.VoucherDate, "dd-MM-yyyy", $null) } catch {}
        $cboAccount.Text = $v.AccountText; $txtCity.Text = $v.City; $txtNarr.Text = $v.Narration; $txtAmount.Text = $v.Amount
        $script:EditingCRVoucherNo = $v.VoucherNo
    }

    $btnSave.Add_Click({
        if ($cboAccount.Text.Trim() -eq "") {
            [System.Windows.Forms.MessageBox]::Show("Pehle account select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        $amt = 0.0
        if (-not [double]::TryParse($txtAmount.Text, [ref]$amt) -or $amt -le 0) {
            [System.Windows.Forms.MessageBox]::Show("Sahi Amount dalein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        $voucher = Get-CurrentVoucherObject
        $existingRows = @(Read-JsonArray $CashReceiptsFile)
        $auditAction = if ($script:EditingCRVoucherNo) { "Edit" } else { "Create" }
        if ($script:EditingCRVoucherNo) {
            $existingRows = @($existingRows | Where-Object { "$($_.VoucherNo)" -ne "$($script:EditingCRVoucherNo)" }) + $voucher
        } else {
            $existingRows = $existingRows + $voucher
        }
        Save-JsonArray $CashReceiptsFile $existingRows
        Add-AuditLog -Action $auditAction -Entity "Cash Receipt Voucher" -Details "Voucher No $($voucher.VoucherNo) - $($voucher.AccountText) - Rs. $($voucher.Amount)"
        [System.Windows.Forms.MessageBox]::Show("Cash Receipt Voucher No $($voucher.VoucherNo) save ho gaya.", "Nav Durga Sports", "OK", "Information") | Out-Null
        $form.Close()
    })
    $btnNew.Add_Click({ Reset-Form })
    $btnClose.Add_Click({ $form.Close() })

    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'F2') { $btnNew.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'F3') { $btnSave.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'Return') {
            $ac = $form.ActiveControl
            if ($ac -and ($ac -is [System.Windows.Forms.TextBox] -or $ac -is [System.Windows.Forms.ComboBox] -or $ac -is [System.Windows.Forms.DateTimePicker]) -and -not ($ac -is [System.Windows.Forms.TextBox] -and $ac.ReadOnly)) {
                $form.SelectNextControl($ac, $true, $true, $true, $true) | Out-Null
                $e.Handled = $true; $e.SuppressKeyPress = $true
            }
        }
    })

    Reset-Form
    if ($Existing) { Load-VoucherIntoForm $Existing }
    $form.ShowDialog() | Out-Null
}

function Show-CashReceiptListForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Cash Receipt Voucher List"
    $form.Size = New-Object System.Drawing.Size(950, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(950, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "CASH RECEIPT VOUCHER LIST" 934))

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search:"; $lblSearch.Font = $FontBold; $lblSearch.AutoSize = $true
    $lblSearch.Location = New-Object System.Drawing.Point(12, 54)
    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(75, 51); $txtSearch.Size = New-Object System.Drawing.Size(300, 24)
    $btnClearSearch = New-Object System.Windows.Forms.Button
    $btnClearSearch.Text = "Clear"; $btnClearSearch.Font = $FontNormal; $btnClearSearch.Size = New-Object System.Drawing.Size(70, 26)
    $btnClearSearch.Location = New-Object System.Drawing.Point(385, 49)
    $form.Controls.Add($lblSearch) | Out-Null
    $form.Controls.Add($txtSearch) | Out-Null
    $form.Controls.Add($btnClearSearch) | Out-Null

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 88); $grid.Size = New-Object System.Drawing.Size(910, 362)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("VoucherNo", "Voucher No") | Out-Null
    $grid.Columns.Add("VoucherDate", "Voucher Date") | Out-Null
    $grid.Columns.Add("AccCode", "Account Code") | Out-Null
    $grid.Columns.Add("AccDesc", "Account Description") | Out-Null
    $grid.Columns.Add("AccCity", "Account City") | Out-Null
    $grid.Columns.Add("Narration", "Narration") | Out-Null
    $grid.Columns.Add("Amount", "Amount") | Out-Null
    $grid.Columns["VoucherNo"].Width = 90; $grid.Columns["VoucherDate"].Width = 100; $grid.Columns["AccCode"].Width = 90
    $grid.Columns["AccDesc"].Width = 220; $grid.Columns["AccCity"].Width = 120; $grid.Columns["Narration"].Width = 180; $grid.Columns["Amount"].Width = 100
    $grid.Columns["Amount"].DefaultCellStyle.Alignment = "MiddleRight"
    $form.Controls.Add($grid)

    $script:CashReceiptData = @()
    function Load-Grid {
        $grid.Rows.Clear()
        $all = @(Read-JsonArray $CashReceiptsFile) | Sort-Object { [int]($_.VoucherNo -replace '[^0-9]','') } -Descending
        $q = $txtSearch.Text.Trim()
        $script:CashReceiptData = if ($q -eq "") { $all } else {
            $all | Where-Object { "$($_.AccountText)" -like "*$q*" -or "$($_.Narration)" -like "*$q*" -or "$($_.VoucherNo)" -like "*$q*" -or "$($_.City)" -like "*$q*" }
        }
        foreach ($v in $script:CashReceiptData) {
            $parts = "$($v.AccountText)" -split ' - '
            $accCode = $parts[0]
            $accDesc = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            $grid.Rows.Add($v.VoucherNo, $v.VoucherDate, $accCode, $accDesc, $v.City, $v.Narration, $v.Amount) | Out-Null
        }
        $lblCount.Text = "Record(s): $($grid.Rows.Count)"
    }

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Text = "Record(s): 0"
    $lblCount.Location = New-Object System.Drawing.Point(12, 458); $lblCount.AutoSize = $true
    $lblCount.Anchor = "Bottom, Left"

    function Get-SelectedVoucher {
        if ($grid.SelectedRows.Count -eq 0) { return $null }
        $vno = $grid.SelectedRows[0].Cells["VoucherNo"].Value
        return $script:CashReceiptData | Where-Object { "$($_.VoucherNo)" -eq "$vno" } | Select-Object -First 1
    }

    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = "New Receipt"; $btnNew.Font = $FontBold; $btnNew.Size = New-Object System.Drawing.Size(140, 34)
    $btnNew.Location = New-Object System.Drawing.Point(12, 480); $btnNew.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnNew.Anchor = "Bottom, Left"
    $btnEdit = New-Object System.Windows.Forms.Button
    $btnEdit.Text = "Edit"; $btnEdit.Font = $FontBold; $btnEdit.Size = New-Object System.Drawing.Size(90, 34)
    $btnEdit.Location = New-Object System.Drawing.Point(162, 480); $btnEdit.Anchor = "Bottom, Left"
    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete"; $btnDelete.Font = $FontBold; $btnDelete.Size = New-Object System.Drawing.Size(90, 34)
    $btnDelete.Location = New-Object System.Drawing.Point(262, 480); $btnDelete.BackColor = [System.Drawing.Color]::FromArgb(240, 210, 210)
    $btnDelete.Anchor = "Bottom, Left"
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(362, 480); $btnRefresh.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(832, 480); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($lblCount) | Out-Null
    $form.Controls.Add($btnNew) | Out-Null
    $form.Controls.Add($btnEdit) | Out-Null
    $form.Controls.Add($btnDelete) | Out-Null
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $txtSearch.Add_TextChanged({ Load-Grid })
    $btnClearSearch.Add_Click({ $txtSearch.Text = ""; Load-Grid })
    $btnNew.Add_Click({ Invoke-Safe { Show-CashReceiptVoucherForm }; Load-Grid })
    $btnEdit.Add_Click({
        $v = Get-SelectedVoucher
        if (-not $v) { [System.Windows.Forms.MessageBox]::Show("Pehle ek voucher select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        Invoke-Safe { Show-CashReceiptVoucherForm -Existing $v }
        Load-Grid
    })
    $btnDelete.Add_Click({
        $v = Get-SelectedVoucher
        if (-not $v) { [System.Windows.Forms.MessageBox]::Show("Pehle ek voucher select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Voucher No $($v.VoucherNo) delete karein?", "Nav Durga Sports", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            $remaining = @(Read-JsonArray $CashReceiptsFile) | Where-Object { "$($_.VoucherNo)" -ne "$($v.VoucherNo)" }
            Save-JsonArray $CashReceiptsFile $remaining
            Add-AuditLog -Action "Delete" -Entity "Cash Receipt Voucher" -Details "Voucher No $($v.VoucherNo) - $($v.AccountText)"
            Load-Grid
        }
    })
    $btnRefresh.Add_Click({ Load-Grid })
    $btnClose.Add_Click({ $form.Close() })

    Load-Grid
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  CASH PAYMENT VOUCHER (Data Entry -> "Cash Payment Voucher")
#  Money PAID OUT to a party -> Debit entry in their ledger, mirror image of
#  Purchase Voucher (which is a Credit entry). Same simplified layout as
#  Cash Receipt Voucher above (no items grid).
# ============================================================================
function Show-CashPaymentVoucherForm {
    param($Existing = $null)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Cash Payment Voucher Entry"
    $form.Size = New-Object System.Drawing.Size(760, 400)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 400)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "CASH PAYMENT VOUCHER" 744))

    $grpVou = New-Object System.Windows.Forms.GroupBox
    $grpVou.Text = "Voucher Details"; $grpVou.Font = $FontBold
    $grpVou.Location = New-Object System.Drawing.Point(12, 50); $grpVou.Size = New-Object System.Drawing.Size(720, 60)
    $lblVouNo = New-Object System.Windows.Forms.Label
    $lblVouNo.Text = "Voucher No:"; $lblVouNo.Location = New-Object System.Drawing.Point(15, 25); $lblVouNo.AutoSize = $true
    $txtVouNo = New-Object System.Windows.Forms.TextBox
    $txtVouNo.Location = New-Object System.Drawing.Point(105, 22); $txtVouNo.Size = New-Object System.Drawing.Size(90, 22)
    $txtVouNo.ReadOnly = $true; $txtVouNo.BackColor = [System.Drawing.Color]::LightYellow; $txtVouNo.Font = $FontBold
    $lblVouDate = New-Object System.Windows.Forms.Label
    $lblVouDate.Text = "Voucher Date:"; $lblVouDate.Location = New-Object System.Drawing.Point(220, 25); $lblVouDate.AutoSize = $true
    $dtpVouDate = New-Object System.Windows.Forms.DateTimePicker
    $dtpVouDate.Format = "Short"; $dtpVouDate.Location = New-Object System.Drawing.Point(310, 22); $dtpVouDate.Size = New-Object System.Drawing.Size(110, 22)
    $grpVou.Controls.Add($lblVouNo) | Out-Null
    $grpVou.Controls.Add($txtVouNo) | Out-Null
    $grpVou.Controls.Add($lblVouDate) | Out-Null
    $grpVou.Controls.Add($dtpVouDate) | Out-Null
    $form.Controls.Add($grpVou)

    $grpAcc = New-Object System.Windows.Forms.GroupBox
    $grpAcc.Text = "Paid To"; $grpAcc.Font = $FontBold
    $grpAcc.Location = New-Object System.Drawing.Point(12, 115); $grpAcc.Size = New-Object System.Drawing.Size(720, 130)
    $lblAcc = New-Object System.Windows.Forms.Label
    $lblAcc.Text = "Account:"; $lblAcc.Location = New-Object System.Drawing.Point(15, 28); $lblAcc.AutoSize = $true
    $cboAccount = New-Object System.Windows.Forms.ComboBox
    $cboAccount.Location = New-Object System.Drawing.Point(100, 25); $cboAccount.Size = New-Object System.Drawing.Size(360, 22)
    $cboAccount.DropDownStyle = "DropDown"
    $script:AllCustomers = Get-AllCustomers
    $accList = New-Object System.Collections.ArrayList
    foreach ($c in $script:AllCustomers) { [void]$accList.Add("$($c.Code) - $($c.Name)") }
    $cboAccount.Items.AddRange($accList.ToArray())
    Enable-ComboBoxContainsSearch -Combo $cboAccount -GetAllItems { $accList.ToArray() }
    $lblCity = New-Object System.Windows.Forms.Label
    $lblCity.Text = "City:"; $lblCity.Location = New-Object System.Drawing.Point(475, 28); $lblCity.AutoSize = $true
    $txtCity = New-Object System.Windows.Forms.TextBox
    $txtCity.Location = New-Object System.Drawing.Point(515, 25); $txtCity.Size = New-Object System.Drawing.Size(190, 22); $txtCity.ReadOnly = $true
    $lblAmount = New-Object System.Windows.Forms.Label
    $lblAmount.Text = "Amount:"; $lblAmount.Font = $FontBold; $lblAmount.Location = New-Object System.Drawing.Point(15, 58); $lblAmount.AutoSize = $true
    $txtAmount = New-Object System.Windows.Forms.TextBox
    $txtAmount.Location = New-Object System.Drawing.Point(100, 55); $txtAmount.Size = New-Object System.Drawing.Size(130, 22); $txtAmount.Font = $FontBold; $txtAmount.TextAlign = "Right"
    $lblNarr = New-Object System.Windows.Forms.Label
    $lblNarr.Text = "Narration:"; $lblNarr.Location = New-Object System.Drawing.Point(15, 90); $lblNarr.AutoSize = $true
    $txtNarr = New-Object System.Windows.Forms.TextBox
    $txtNarr.Location = New-Object System.Drawing.Point(100, 87); $txtNarr.Size = New-Object System.Drawing.Size(605, 22)
    $grpAcc.Controls.Add($lblAcc) | Out-Null
    $grpAcc.Controls.Add($cboAccount) | Out-Null
    $grpAcc.Controls.Add($lblCity) | Out-Null
    $grpAcc.Controls.Add($txtCity) | Out-Null
    $grpAcc.Controls.Add($lblAmount) | Out-Null
    $grpAcc.Controls.Add($txtAmount) | Out-Null
    $grpAcc.Controls.Add($lblNarr) | Out-Null
    $grpAcc.Controls.Add($txtNarr) | Out-Null
    $form.Controls.Add($grpAcc)

    function Update-AccountDetails {
        if ($cboAccount.Text.Trim() -eq "") { return }
        $code = ($cboAccount.Text -split ' - ')[0].Trim()
        $c = $script:AllCustomers | Where-Object { "$($_.Code)".Trim() -eq $code } | Select-Object -First 1
        if (-not $c) {
            $typed = $cboAccount.Text.Trim()
            $c = $script:AllCustomers | Where-Object { "$($_.Name)".Trim() -eq $typed } | Select-Object -First 1
        }
        if ($c) { $txtCity.Text = $c.City }
    }
    $cboAccount.Add_SelectedIndexChanged({ Update-AccountDetails })
    $cboAccount.Add_Leave({ Update-AccountDetails })

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save Voucher"; $btnSave.Font = $FontBold; $btnSave.Size = New-Object System.Drawing.Size(140, 34)
    $btnSave.Location = New-Object System.Drawing.Point(12, 300); $btnSave.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnSave.Anchor = "Bottom, Left"
    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = "New Voucher"; $btnNew.Font = $FontNormal; $btnNew.Size = New-Object System.Drawing.Size(130, 34)
    $btnNew.Location = New-Object System.Drawing.Point(162, 300); $btnNew.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(642, 300); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnSave) | Out-Null
    $form.Controls.Add($btnNew) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $script:EditingCPVoucherNo = $null
    function Reset-Form {
        $txtVouNo.Text = Get-NextCashPaymentNo
        $dtpVouDate.Value = Get-Date
        $cboAccount.Text = ""; $txtCity.Text = ""; $txtNarr.Text = ""; $txtAmount.Text = "0.00"
        $script:EditingCPVoucherNo = $null
    }
    function Get-CurrentVoucherObject {
        return [PSCustomObject]@{
            VoucherNo = $txtVouNo.Text; VoucherDate = $dtpVouDate.Value.ToString("dd-MM-yyyy")
            AccountText = $cboAccount.Text; City = $txtCity.Text; Narration = $txtNarr.Text
            Amount = $txtAmount.Text; SavedAt = (Get-Date).ToString("s")
        }
    }
    function Load-VoucherIntoForm($v) {
        $txtVouNo.Text = $v.VoucherNo
        try { $dtpVouDate.Value = [DateTime]::ParseExact($v.VoucherDate, "dd-MM-yyyy", $null) } catch {}
        $cboAccount.Text = $v.AccountText; $txtCity.Text = $v.City; $txtNarr.Text = $v.Narration; $txtAmount.Text = $v.Amount
        $script:EditingCPVoucherNo = $v.VoucherNo
    }

    $btnSave.Add_Click({
        if ($cboAccount.Text.Trim() -eq "") {
            [System.Windows.Forms.MessageBox]::Show("Pehle account select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        $amt = 0.0
        if (-not [double]::TryParse($txtAmount.Text, [ref]$amt) -or $amt -le 0) {
            [System.Windows.Forms.MessageBox]::Show("Sahi Amount dalein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return
        }
        $voucher = Get-CurrentVoucherObject
        $existingRows = @(Read-JsonArray $CashPaymentsFile)
        $auditAction = if ($script:EditingCPVoucherNo) { "Edit" } else { "Create" }
        if ($script:EditingCPVoucherNo) {
            $existingRows = @($existingRows | Where-Object { "$($_.VoucherNo)" -ne "$($script:EditingCPVoucherNo)" }) + $voucher
        } else {
            $existingRows = $existingRows + $voucher
        }
        Save-JsonArray $CashPaymentsFile $existingRows
        Add-AuditLog -Action $auditAction -Entity "Cash Payment Voucher" -Details "Voucher No $($voucher.VoucherNo) - $($voucher.AccountText) - Rs. $($voucher.Amount)"
        [System.Windows.Forms.MessageBox]::Show("Cash Payment Voucher No $($voucher.VoucherNo) save ho gaya.", "Nav Durga Sports", "OK", "Information") | Out-Null
        $form.Close()
    })
    $btnNew.Add_Click({ Reset-Form })
    $btnClose.Add_Click({ $form.Close() })

    $form.KeyPreview = $true
    $form.Add_KeyDown({
        param($s, $e)
        if ($e.KeyCode -eq 'F2') { $btnNew.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'F3') { $btnSave.PerformClick(); $e.Handled = $true; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq 'Return') {
            $ac = $form.ActiveControl
            if ($ac -and ($ac -is [System.Windows.Forms.TextBox] -or $ac -is [System.Windows.Forms.ComboBox] -or $ac -is [System.Windows.Forms.DateTimePicker]) -and -not ($ac -is [System.Windows.Forms.TextBox] -and $ac.ReadOnly)) {
                $form.SelectNextControl($ac, $true, $true, $true, $true) | Out-Null
                $e.Handled = $true; $e.SuppressKeyPress = $true
            }
        }
    })

    Reset-Form
    if ($Existing) { Load-VoucherIntoForm $Existing }
    $form.ShowDialog() | Out-Null
}

function Show-CashPaymentListForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Cash Payment Voucher List"
    $form.Size = New-Object System.Drawing.Size(950, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(950, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "CASH PAYMENT VOUCHER LIST" 934))

    $lblSearch = New-Object System.Windows.Forms.Label
    $lblSearch.Text = "Search:"; $lblSearch.Font = $FontBold; $lblSearch.AutoSize = $true
    $lblSearch.Location = New-Object System.Drawing.Point(12, 54)
    $txtSearch = New-Object System.Windows.Forms.TextBox
    $txtSearch.Location = New-Object System.Drawing.Point(75, 51); $txtSearch.Size = New-Object System.Drawing.Size(300, 24)
    $btnClearSearch = New-Object System.Windows.Forms.Button
    $btnClearSearch.Text = "Clear"; $btnClearSearch.Font = $FontNormal; $btnClearSearch.Size = New-Object System.Drawing.Size(70, 26)
    $btnClearSearch.Location = New-Object System.Drawing.Point(385, 49)
    $form.Controls.Add($lblSearch) | Out-Null
    $form.Controls.Add($txtSearch) | Out-Null
    $form.Controls.Add($btnClearSearch) | Out-Null

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 88); $grid.Size = New-Object System.Drawing.Size(910, 362)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("VoucherNo", "Voucher No") | Out-Null
    $grid.Columns.Add("VoucherDate", "Voucher Date") | Out-Null
    $grid.Columns.Add("AccCode", "Account Code") | Out-Null
    $grid.Columns.Add("AccDesc", "Account Description") | Out-Null
    $grid.Columns.Add("AccCity", "Account City") | Out-Null
    $grid.Columns.Add("Narration", "Narration") | Out-Null
    $grid.Columns.Add("Amount", "Amount") | Out-Null
    $grid.Columns["VoucherNo"].Width = 90; $grid.Columns["VoucherDate"].Width = 100; $grid.Columns["AccCode"].Width = 90
    $grid.Columns["AccDesc"].Width = 220; $grid.Columns["AccCity"].Width = 120; $grid.Columns["Narration"].Width = 180; $grid.Columns["Amount"].Width = 100
    $grid.Columns["Amount"].DefaultCellStyle.Alignment = "MiddleRight"
    $form.Controls.Add($grid)

    $script:CashPaymentData = @()
    function Load-Grid {
        $grid.Rows.Clear()
        $all = @(Read-JsonArray $CashPaymentsFile) | Sort-Object { [int]($_.VoucherNo -replace '[^0-9]','') } -Descending
        $q = $txtSearch.Text.Trim()
        $script:CashPaymentData = if ($q -eq "") { $all } else {
            $all | Where-Object { "$($_.AccountText)" -like "*$q*" -or "$($_.Narration)" -like "*$q*" -or "$($_.VoucherNo)" -like "*$q*" -or "$($_.City)" -like "*$q*" }
        }
        foreach ($v in $script:CashPaymentData) {
            $parts = "$($v.AccountText)" -split ' - '
            $accCode = $parts[0]
            $accDesc = if ($parts.Count -gt 1) { $parts[1] } else { "" }
            $grid.Rows.Add($v.VoucherNo, $v.VoucherDate, $accCode, $accDesc, $v.City, $v.Narration, $v.Amount) | Out-Null
        }
        $lblCount.Text = "Record(s): $($grid.Rows.Count)"
    }

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Text = "Record(s): 0"
    $lblCount.Location = New-Object System.Drawing.Point(12, 458); $lblCount.AutoSize = $true
    $lblCount.Anchor = "Bottom, Left"

    function Get-SelectedVoucher {
        if ($grid.SelectedRows.Count -eq 0) { return $null }
        $vno = $grid.SelectedRows[0].Cells["VoucherNo"].Value
        return $script:CashPaymentData | Where-Object { "$($_.VoucherNo)" -eq "$vno" } | Select-Object -First 1
    }

    $btnNew = New-Object System.Windows.Forms.Button
    $btnNew.Text = "New Payment"; $btnNew.Font = $FontBold; $btnNew.Size = New-Object System.Drawing.Size(140, 34)
    $btnNew.Location = New-Object System.Drawing.Point(12, 480); $btnNew.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnNew.Anchor = "Bottom, Left"
    $btnEdit = New-Object System.Windows.Forms.Button
    $btnEdit.Text = "Edit"; $btnEdit.Font = $FontBold; $btnEdit.Size = New-Object System.Drawing.Size(90, 34)
    $btnEdit.Location = New-Object System.Drawing.Point(162, 480); $btnEdit.Anchor = "Bottom, Left"
    $btnDelete = New-Object System.Windows.Forms.Button
    $btnDelete.Text = "Delete"; $btnDelete.Font = $FontBold; $btnDelete.Size = New-Object System.Drawing.Size(90, 34)
    $btnDelete.Location = New-Object System.Drawing.Point(262, 480); $btnDelete.BackColor = [System.Drawing.Color]::FromArgb(240, 210, 210)
    $btnDelete.Anchor = "Bottom, Left"
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(362, 480); $btnRefresh.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(832, 480); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($lblCount) | Out-Null
    $form.Controls.Add($btnNew) | Out-Null
    $form.Controls.Add($btnEdit) | Out-Null
    $form.Controls.Add($btnDelete) | Out-Null
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $txtSearch.Add_TextChanged({ Load-Grid })
    $btnClearSearch.Add_Click({ $txtSearch.Text = ""; Load-Grid })
    $btnNew.Add_Click({ Invoke-Safe { Show-CashPaymentVoucherForm }; Load-Grid })
    $btnEdit.Add_Click({
        $v = Get-SelectedVoucher
        if (-not $v) { [System.Windows.Forms.MessageBox]::Show("Pehle ek voucher select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        Invoke-Safe { Show-CashPaymentVoucherForm -Existing $v }
        Load-Grid
    })
    $btnDelete.Add_Click({
        $v = Get-SelectedVoucher
        if (-not $v) { [System.Windows.Forms.MessageBox]::Show("Pehle ek voucher select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null; return }
        $confirm = [System.Windows.Forms.MessageBox]::Show("Voucher No $($v.VoucherNo) delete karein?", "Nav Durga Sports", "YesNo", "Question")
        if ($confirm -eq "Yes") {
            $remaining = @(Read-JsonArray $CashPaymentsFile) | Where-Object { "$($_.VoucherNo)" -ne "$($v.VoucherNo)" }
            Save-JsonArray $CashPaymentsFile $remaining
            Add-AuditLog -Action "Delete" -Entity "Cash Payment Voucher" -Details "Voucher No $($v.VoucherNo) - $($v.AccountText)"
            Load-Grid
        }
    })
    $btnRefresh.Add_Click({ Load-Grid })
    $btnClose.Add_Click({ $form.Close() })

    Load-Grid
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  STOCK SUMMARY (Reports -> "Stock")
#  Current Stock = Opening Qty (Vineet ki di hui shuruaati qty, editable) +
#  Total Purchased (Purchase Vouchers ke sabhi items) - Total Issued (Rough
#  Estimate bills ke sabhi items). Har product ke liye ek row.
# ============================================================================
function Get-ProductStockSummary {
    $opening = @{}
    foreach ($o in (Read-JsonArray $StockOpeningFile)) {
        $opening["$($o.Code)".Trim()] = 0.0
        [double]::TryParse("$($o.Qty)", [ref]$opening["$($o.Code)".Trim()]) | Out-Null
    }
    $purchased = @{}
    foreach ($v in (Read-JsonArray $PurchaseVouchersFile)) {
        foreach ($it in $v.Items) {
            $code = "$($it.Code)".Trim(); if ($code -eq "") { continue }
            $q = 0.0; [double]::TryParse("$($it.Qty)", [ref]$q) | Out-Null
            if (-not $purchased.ContainsKey($code)) { $purchased[$code] = 0.0 }
            $purchased[$code] += $q
        }
    }
    $issued = @{}
    foreach ($b in (Read-JsonArray $BillsFile)) {
        foreach ($it in $b.Items) {
            $code = "$($it.Code)".Trim(); if ($code -eq "") { continue }
            $q = 0.0; [double]::TryParse("$($it.Qty)", [ref]$q) | Out-Null
            if (-not $issued.ContainsKey($code)) { $issued[$code] = 0.0 }
            $issued[$code] += $q
        }
    }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($p in $script:AllProducts) {
        $code = "$($p.Code)".Trim()
        $op = 0.0; if ($opening.ContainsKey($code)) { $op = $opening[$code] }
        $pur = 0.0; if ($purchased.ContainsKey($code)) { $pur = $purchased[$code] }
        $iss = 0.0; if ($issued.ContainsKey($code)) { $iss = $issued[$code] }
        $result.Add([PSCustomObject]@{
            Code = $code; Desc = $p.Desc; Opening = $op; Purchased = $pur; Issued = $iss
            Current = [Math]::Round($op + $pur - $iss, 2)
        })
    }
    return $result
}

function Show-StockSummaryForm {
    $script:AllProducts = Get-AllProducts
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Stock Summary"
    $form.Size = New-Object System.Drawing.Size(820, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(820, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "STOCK SUMMARY" 804))

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Text = "Opening Qty column double-click karke edit kar sakte hain. Current Stock = Opening + Purchased (Purchase Voucher) - Issued (Rough Estimate)."
    $lblNote.AutoSize = $true
    $lblNote.Location = New-Object System.Drawing.Point(12, 46)
    $form.Controls.Add($lblNote)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 68); $grid.Size = New-Object System.Drawing.Size(780, 400)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Code", "Product Code") | Out-Null
    $grid.Columns.Add("Desc", "Product Description") | Out-Null
    $colOpen = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $colOpen.Name = "Opening"; $colOpen.HeaderText = "Opening Qty"
    $grid.Columns.Add($colOpen) | Out-Null
    $grid.Columns.Add("Purchased", "Purchased Qty") | Out-Null
    $grid.Columns.Add("Issued", "Issued Qty") | Out-Null
    $grid.Columns.Add("Current", "Current Stock") | Out-Null
    $grid.Columns["Code"].Width = 100; $grid.Columns["Desc"].Width = 260
    $grid.Columns["Opening"].Width = 100; $grid.Columns["Purchased"].Width = 100
    $grid.Columns["Issued"].Width = 90; $grid.Columns["Current"].Width = 110
    $grid.Columns["Opening"].DefaultCellStyle.Alignment = "MiddleRight"; $grid.Columns["Opening"].DefaultCellStyle.BackColor = [System.Drawing.Color]::LightYellow
    $grid.Columns["Purchased"].DefaultCellStyle.Alignment = "MiddleRight"
    $grid.Columns["Issued"].DefaultCellStyle.Alignment = "MiddleRight"
    $grid.Columns["Current"].DefaultCellStyle.Alignment = "MiddleRight"; $grid.Columns["Current"].DefaultCellStyle.Font = $FontBold
    $grid.ReadOnly = $false
    foreach ($c in $grid.Columns) { $c.ReadOnly = $true; $c.SortMode = "NotSortable" }
    $grid.Columns["Opening"].ReadOnly = $false
    $form.Controls.Add($grid)

    function Load-Grid {
        $grid.Rows.Clear()
        foreach ($row in (Get-ProductStockSummary)) {
            $grid.Rows.Add($row.Code, $row.Desc, $row.Opening, $row.Purchased, $row.Issued, $row.Current) | Out-Null
        }
    }

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Text = ""
    $lblCount.Location = New-Object System.Drawing.Point(12, 478); $lblCount.AutoSize = $true
    $lblCount.Anchor = "Bottom, Left"
    $form.Controls.Add($lblCount)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save Opening Qty"; $btnSave.Font = $FontBold; $btnSave.Size = New-Object System.Drawing.Size(150, 34)
    $btnSave.Location = New-Object System.Drawing.Point(12, 500); $btnSave.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnSave.Anchor = "Bottom, Left"
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(172, 500)
    $btnRefresh.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(702, 500)
    $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnSave) | Out-Null
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $btnSave.Add_Click({
        $openingList = @()
        foreach ($row in $grid.Rows) {
            if ($row.IsNewRow) { continue }
            $code = "$($row.Cells['Code'].Value)".Trim()
            $qty = 0.0; [double]::TryParse("$($row.Cells['Opening'].Value)", [ref]$qty) | Out-Null
            $openingList += [PSCustomObject]@{ Code = $code; Qty = $qty }
        }
        Save-JsonArray $StockOpeningFile $openingList
        Add-AuditLog -Action "Edit" -Entity "Stock Opening" -Details "$($openingList.Count) product(s) ki Opening Qty update hui"
        [System.Windows.Forms.MessageBox]::Show("Opening Qty save ho gayi.", "Nav Durga Sports", "OK", "Information") | Out-Null
        Load-Grid
    })
    $btnRefresh.Add_Click({ Load-Grid })
    $btnClose.Add_Click({ $form.Close() })

    Load-Grid
    $lblCount.Text = "Product(s): $($grid.Rows.Count)"
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  STOCK TRANSACTIONS - every Purchase (IN) and Rough Estimate Issue (OUT),
#  item-wise, in one chronological list. Used by both "Stock(Trans.)" (all
#  products together) and "Stock Ledger" (one product, running balance).
# ============================================================================
function Get-StockTransactions {
    param([string]$FilterCode = "")
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($v in (Read-JsonArray $PurchaseVouchersFile)) {
        $dt = $null
        try { $dt = [DateTime]::ParseExact("$($v.VoucherDate)", "dd-MM-yyyy", $null) } catch { $dt = $null }
        if (-not $dt) { continue }
        foreach ($it in $v.Items) {
            $code = "$($it.Code)".Trim(); if ($code -eq "") { continue }
            if ($FilterCode -ne "" -and $code -ne $FilterCode) { continue }
            $q = 0.0; [double]::TryParse("$($it.Qty)", [ref]$q) | Out-Null
            $partyParts = "$($v.AccountText)" -split ' - '
            $party = if ($partyParts.Count -gt 1) { $partyParts[1] } else { $partyParts[0] }
            $rows.Add([PSCustomObject]@{
                Date = $dt; Code = $code; Desc = "$($it.Description)"; Type = "IN (Purchase)"
                Qty = $q; RefNo = "PV$($v.VoucherNo)"; Party = $party
            })
        }
    }
    foreach ($b in (Read-JsonArray $BillsFile)) {
        $dt = $null
        try { $dt = [DateTime]::ParseExact("$($b.BillDate)", "dd-MM-yyyy", $null) } catch { $dt = $null }
        if (-not $dt) { continue }
        foreach ($it in $b.Items) {
            $code = "$($it.Code)".Trim(); if ($code -eq "") { continue }
            if ($FilterCode -ne "" -and $code -ne $FilterCode) { continue }
            $q = 0.0; [double]::TryParse("$($it.Qty)", [ref]$q) | Out-Null
            $partyParts = "$($b.CustomerText)" -split ' - '
            $party = if ($partyParts.Count -gt 1) { $partyParts[1] } else { $partyParts[0] }
            $rows.Add([PSCustomObject]@{
                Date = $dt; Code = $code; Desc = "$($it.Description)"; Type = "OUT (Sale)"
                Qty = $q; RefNo = "SL$($b.BillNo)"; Party = $party
            })
        }
    }
    return @($rows | Sort-Object Date)
}

# ============================================================================
#  TRIAL BALANCE (Reports -> "Trial Balance")
#  Party-wise closing balance (Dr/Cr), from the same maths as Party Ledger.
#  NOTE: this software doesn't post to ledger heads (Sales/Purchase/Cash
#  accounts) yet, so Total Dr will NOT necessarily equal Total Cr - this is
#  only the parties' side (who owes Vineet, and who Vineet owes), not a full
#  double-entry Trial Balance.
# ============================================================================
function Show-TrialBalanceForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Trial Balance"
    $form.Size = New-Object System.Drawing.Size(760, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(760, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "TRIAL BALANCE (PARTY-WISE)" 744))

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Text = "Har party ka closing balance (Udhari = Dr, Advance = Cr). Yeh Sales/Purchase/Cash accounts wala poora double-entry Trial Balance nahi hai, sirf party-wise summary hai."
    $lblNote.AutoSize = $true; $lblNote.Location = New-Object System.Drawing.Point(12, 46)
    $form.Controls.Add($lblNote)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 68); $grid.Size = New-Object System.Drawing.Size(720, 400)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Code", "Code") | Out-Null
    $grid.Columns.Add("Name", "Party Name") | Out-Null
    $grid.Columns.Add("Debit", "Debit (Dr)") | Out-Null
    $grid.Columns.Add("Credit", "Credit (Cr)") | Out-Null
    $grid.Columns["Code"].Width = 80; $grid.Columns["Name"].Width = 300
    $grid.Columns["Debit"].Width = 150; $grid.Columns["Credit"].Width = 150
    $grid.Columns["Debit"].DefaultCellStyle.Alignment = "MiddleRight"
    $grid.Columns["Credit"].DefaultCellStyle.Alignment = "MiddleRight"
    $form.Controls.Add($grid)

    $lblTotal = New-Object System.Windows.Forms.Label
    $lblTotal.Text = ""; $lblTotal.Font = $FontBold
    $lblTotal.Location = New-Object System.Drawing.Point(12, 478); $lblTotal.AutoSize = $true
    $lblTotal.Anchor = "Bottom, Left"
    $form.Controls.Add($lblTotal)

    function Load-TrialBalance {
        $grid.Rows.Clear()
        $totalDr = 0.0; $totalCr = 0.0
        foreach ($p in (Get-AllPartyBalances)) {
            $drStr = ""; $crStr = ""
            if ($p.CrDr -eq "Dr") { $drStr = $p.Amount.ToString("N2"); $totalDr += $p.Amount }
            else { $crStr = $p.Amount.ToString("N2"); $totalCr += $p.Amount }
            $grid.Rows.Add($p.Code, $p.Name, $drStr, $crStr) | Out-Null
        }
        $lblTotal.Text = "Total Debit: Rs. $($totalDr.ToString('N2'))      Total Credit: Rs. $($totalCr.ToString('N2'))      Party(s): $($grid.Rows.Count)"
    }

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(12, 500); $btnRefresh.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(642, 500); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null
    $btnRefresh.Add_Click({ Load-TrialBalance })
    $btnClose.Add_Click({ $form.Close() })

    Load-TrialBalance
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  OUTSTANDING / UDHARI LIST (Reports -> "Outstanding / Udhari List")
#  Sirf woh parties jo Dr hain (jinse paisa aana hai), sabse zyada udhari
#  upar. Mobile number Get-AllCustomers (overrides sahit) se aata hai, aur
#  ek click mein WhatsApp reminder bhej sakte hain (Send-WhatsAppMessage).
# ============================================================================
function Show-OutstandingListForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Outstanding / Udhari List"
    $form.Size = New-Object System.Drawing.Size(820, 580)
    $form.MinimumSize = New-Object System.Drawing.Size(820, 580)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "OUTSTANDING / UDHARI LIST" 804))

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Text = "Jo party Dr hai (aapko unse paisa lena baaki hai) unki list, sabse zyada udhari upar. Kisi party ko select karke 'Send Reminder' se WhatsApp par yaad dilayein."
    $lblNote.AutoSize = $true; $lblNote.MaximumSize = New-Object System.Drawing.Size(780,0)
    $lblNote.Location = New-Object System.Drawing.Point(12, 46)
    $form.Controls.Add($lblNote)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 78); $grid.Size = New-Object System.Drawing.Size(780, 380)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Code", "Code") | Out-Null
    $grid.Columns.Add("Name", "Party Name") | Out-Null
    $grid.Columns.Add("Mobile", "Mobile") | Out-Null
    $grid.Columns.Add("Amount", "Udhari (Rs.)") | Out-Null
    $grid.Columns["Code"].Width = 70; $grid.Columns["Name"].Width = 280
    $grid.Columns["Mobile"].Width = 140; $grid.Columns["Amount"].Width = 150
    $grid.Columns["Amount"].DefaultCellStyle.Alignment = "MiddleRight"
    $grid.SelectionMode = "FullRowSelect"; $grid.MultiSelect = $false
    $form.Controls.Add($grid)

    $lblTotal = New-Object System.Windows.Forms.Label
    $lblTotal.Text = ""; $lblTotal.Font = $FontBold
    $lblTotal.Location = New-Object System.Drawing.Point(12, 462); $lblTotal.AutoSize = $true
    $lblTotal.Anchor = "Bottom, Left"
    $form.Controls.Add($lblTotal)

    function Load-OutstandingList {
        $grid.Rows.Clear()
        $custMap = @{}
        foreach ($c in (Get-AllCustomers)) { $custMap["$($c.Code)".Trim()] = $c }
        $total = 0.0
        $rows = (Get-AllPartyBalances) | Where-Object { $_.CrDr -eq "Dr" } | Sort-Object -Property Amount -Descending
        foreach ($p in $rows) {
            $mob = ""
            if ($custMap.ContainsKey("$($p.Code)".Trim())) { $mob = "$($custMap["$($p.Code)".Trim()].Mobile)".Trim() }
            $grid.Rows.Add($p.Code, $p.Name, $mob, $p.Amount.ToString("N2")) | Out-Null
            $total += $p.Amount
        }
        $lblTotal.Text = "Total Outstanding (Udhari): Rs. $($total.ToString('N2'))      Party(s): $($grid.Rows.Count)"
    }

    $btnReminder = New-Object System.Windows.Forms.Button
    $btnReminder.Text = "Send Reminder (WhatsApp)"; $btnReminder.Font = $FontNormal; $btnReminder.Size = New-Object System.Drawing.Size(190, 34)
    $btnReminder.Location = New-Object System.Drawing.Point(12, 500); $btnReminder.Anchor = "Bottom, Left"
    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(212, 500); $btnRefresh.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(702, 500); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnReminder) | Out-Null
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $btnReminder.Add_Click({
        if ($grid.SelectedRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Pehle list mein se ek party select karein.", "Nav Durga Sports", "OK", "Warning") | Out-Null
            return
        }
        $row = $grid.SelectedRows[0]
        $name = "$($row.Cells['Name'].Value)"
        $mob = "$($row.Cells['Mobile'].Value)".Trim()
        $amt = "$($row.Cells['Amount'].Value)"
        if ($mob -eq "") {
            [System.Windows.Forms.MessageBox]::Show("$name ka mobile number nahi mila. Pehle Customer Master mein Edit karke mobile number daalein.", "Nav Durga Sports", "OK", "Warning") | Out-Null
            return
        }
        $msg = "Namaste $name ji,`nNav Durga Sports (DASH X) ki taraf se - aapka outstanding balance Rs. $amt hai. Kripya jald hi bhugtan kar dijiye. Dhanyawad."
        Send-WhatsAppMessage -Mobile $mob -Message $msg
    })
    $btnRefresh.Add_Click({ Load-OutstandingList })
    $btnClose.Add_Click({ $form.Close() })

    Load-OutstandingList
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  CASH DAY BOOK (Reports -> "Cash Day Book")
#  Day-wise Cash/Bank Receipts against parties (cashrecd.dbf). Jab "Cash
#  Payment Voucher" screen bhi banegi, uska data yahan apne aap jud jayega.
# ============================================================================
function Show-CashDayBookForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Cash Day Book"
    $form.Size = New-Object System.Drawing.Size(820, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(820, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "CASH DAY BOOK (RECEIPTS)" 804))

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Text = "Din-wise Cash/Bank Receipts. Cash Payment Voucher chalu hote hi uska data bhi yahan aayega."
    $lblNote.AutoSize = $true; $lblNote.Location = New-Object System.Drawing.Point(12, 46)
    $form.Controls.Add($lblNote)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 68); $grid.Size = New-Object System.Drawing.Size(780, 400)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Date", "Date") | Out-Null
    $grid.Columns.Add("VouNo", "Vou.No") | Out-Null
    $grid.Columns.Add("Party", "Party") | Out-Null
    $grid.Columns.Add("Narration", "Narration") | Out-Null
    $grid.Columns.Add("Amount", "Amount (Rs.)") | Out-Null
    $grid.Columns["Date"].Width = 100; $grid.Columns["VouNo"].Width = 90; $grid.Columns["Party"].Width = 240
    $grid.Columns["Narration"].Width = 200; $grid.Columns["Amount"].Width = 130
    $grid.Columns["Amount"].DefaultCellStyle.Alignment = "MiddleRight"
    $form.Controls.Add($grid)

    $lblTotal = New-Object System.Windows.Forms.Label
    $lblTotal.Text = ""; $lblTotal.Font = $FontBold
    $lblTotal.Location = New-Object System.Drawing.Point(12, 478); $lblTotal.AutoSize = $true
    $lblTotal.Anchor = "Bottom, Left"
    $form.Controls.Add($lblTotal)

    function Load-CashBook {
        $grid.Rows.Clear()
        $grandTotal = 0.0
        $entries = New-Object System.Collections.Generic.List[object]
        foreach ($r in $script:OldReceipts) {
            $dt = ConvertTo-DbfDate $r.CR_DATE
            if (-not $dt) { continue }
            $cust = $script:OldCustomers | Where-Object { "$($_.AC_CODE)".Trim() -eq "$($r.CR_CUCD)".Trim() } | Select-Object -First 1
            $partyName = if ($cust) { "$($cust.AC_NAME)".Trim() } else { "$($r.CR_CUCD)".Trim() }
            $entries.Add([PSCustomObject]@{
                Date = $dt; VouNo = "CR$($r.CR_NO)"; Party = $partyName
                Narration = "$($r.CR_NARR)".Trim(); Amount = [double]$r.CR_AMT
            })
        }
        foreach ($e in ($entries | Sort-Object Date)) {
            $grid.Rows.Add($e.Date.ToString("dd-MM-yyyy"), $e.VouNo, $e.Party, $e.Narration, $e.Amount.ToString("N2")) | Out-Null
            $grandTotal += $e.Amount
        }
        $lblTotal.Text = "Total Receipts: Rs. $($grandTotal.ToString('N2'))      Entries: $($grid.Rows.Count)"
    }

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(12, 500); $btnRefresh.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(702, 500); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null
    $btnRefresh.Add_Click({ Load-CashBook })
    $btnClose.Add_Click({ $form.Close() })

    Load-CashBook
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  JOURNAL DAY BOOK (Reports -> "Journal Day Book")
#  Har Purchase Voucher ek Journal-type entry hai (Dr Purchase / Cr Party) -
#  jab tak Journal Voucher screen alag se nahi banti, yahi asli journal data
#  hai jo humare paas hai.
# ============================================================================
function Show-JournalDayBookForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Journal Day Book"
    $form.Size = New-Object System.Drawing.Size(860, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(860, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "JOURNAL DAY BOOK (PURCHASE ENTRIES)" 844))

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Text = "Har Purchase Voucher: Dr Purchase A/c, Cr Party A/c. Journal Voucher screen banne par uska data bhi yahan judega."
    $lblNote.AutoSize = $true; $lblNote.Location = New-Object System.Drawing.Point(12, 46)
    $form.Controls.Add($lblNote)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 68); $grid.Size = New-Object System.Drawing.Size(820, 400)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Date", "Date") | Out-Null
    $grid.Columns.Add("VouNo", "Vou.No") | Out-Null
    $grid.Columns.Add("Debit", "Debit A/c") | Out-Null
    $grid.Columns.Add("Credit", "Credit A/c") | Out-Null
    $grid.Columns.Add("Narration", "Narration") | Out-Null
    $grid.Columns.Add("Amount", "Amount (Rs.)") | Out-Null
    $grid.Columns["Date"].Width = 90; $grid.Columns["VouNo"].Width = 80; $grid.Columns["Debit"].Width = 130
    $grid.Columns["Credit"].Width = 200; $grid.Columns["Narration"].Width = 170; $grid.Columns["Amount"].Width = 120
    $grid.Columns["Amount"].DefaultCellStyle.Alignment = "MiddleRight"
    $form.Controls.Add($grid)

    $lblTotal = New-Object System.Windows.Forms.Label
    $lblTotal.Text = ""; $lblTotal.Font = $FontBold
    $lblTotal.Location = New-Object System.Drawing.Point(12, 478); $lblTotal.AutoSize = $true
    $lblTotal.Anchor = "Bottom, Left"
    $form.Controls.Add($lblTotal)

    function Load-JournalBook {
        $grid.Rows.Clear()
        $grandTotal = 0.0
        $vouchers = @(Read-JsonArray $PurchaseVouchersFile) | Sort-Object {
            $d = $null; try { $d = [DateTime]::ParseExact("$($_.VoucherDate)", "dd-MM-yyyy", $null) } catch {}
            if ($d) { $d } else { [DateTime]::MinValue }
        }
        foreach ($v in $vouchers) {
            $parts = "$($v.AccountText)" -split ' - '
            $partyDesc = if ($parts.Count -gt 1) { $parts[1] } else { $parts[0] }
            $amt = 0.0; [double]::TryParse("$($v.Amount)", [ref]$amt) | Out-Null
            $grid.Rows.Add($v.VoucherDate, "PV$($v.VoucherNo)", "Purchase A/c", $partyDesc, $v.Narration, $amt.ToString("N2")) | Out-Null
            $grandTotal += $amt
        }
        $lblTotal.Text = "Total: Rs. $($grandTotal.ToString('N2'))      Entries: $($grid.Rows.Count)"
    }

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(12, 500); $btnRefresh.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(742, 500); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null
    $btnRefresh.Add_Click({ Load-JournalBook })
    $btnClose.Add_Click({ $form.Close() })

    Load-JournalBook
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  STOCK (GROUP) (Reports -> "Stock(Group)")
#  Abhi Product Master mein alag "Group" field nahi hai, isliye Unit
#  (DZ/PC/etc) ko hi group ki tarah use kiya hai - Group Master bante hi
#  yahan asli group-wise summary dikhne lagegi.
# ============================================================================
function Show-StockGroupForm {
    $script:AllProducts = Get-AllProducts
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Stock (Group-wise)"
    $form.Size = New-Object System.Drawing.Size(700, 520)
    $form.MinimumSize = New-Object System.Drawing.Size(700, 520)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "STOCK (GROUP / UNIT-WISE)" 684))

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Text = "Group Master abhi nahi bana, isliye Unit ko group ki tarah dikhaya hai."
    $lblNote.AutoSize = $true; $lblNote.Location = New-Object System.Drawing.Point(12, 46)
    $form.Controls.Add($lblNote)

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 68); $grid.Size = New-Object System.Drawing.Size(660, 360)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Group", "Unit / Group") | Out-Null
    $grid.Columns.Add("Products", "Product(s)") | Out-Null
    $grid.Columns.Add("Current", "Total Current Stock") | Out-Null
    $grid.Columns["Group"].Width = 200; $grid.Columns["Products"].Width = 200; $grid.Columns["Current"].Width = 200
    $grid.Columns["Products"].DefaultCellStyle.Alignment = "MiddleRight"
    $grid.Columns["Current"].DefaultCellStyle.Alignment = "MiddleRight"
    $form.Controls.Add($grid)

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(12, 438); $lblCount.AutoSize = $true; $lblCount.Font = $FontNormal
    $lblCount.Anchor = "Bottom, Left"
    $form.Controls.Add($lblCount)

    function Load-Grid {
        $grid.Rows.Clear()
        $summary = Get-ProductStockSummary
        $byUnit = @{}
        foreach ($row in $summary) {
            $p = $script:AllProducts | Where-Object { "$($_.Code)".Trim() -eq "$($row.Code)".Trim() } | Select-Object -First 1
            $unit = if ($p -and "$($p.Unit)".Trim() -ne "") { "$($p.Unit)".Trim() } else { "(No Unit)" }
            if (-not $byUnit.ContainsKey($unit)) { $byUnit[$unit] = [PSCustomObject]@{ Count = 0; Total = 0.0 } }
            $byUnit[$unit].Count++
            $byUnit[$unit].Total += $row.Current
        }
        foreach ($unit in ($byUnit.Keys | Sort-Object)) {
            $grid.Rows.Add($unit, $byUnit[$unit].Count, $byUnit[$unit].Total) | Out-Null
        }
        $lblCount.Text = "Group(s): $($grid.Rows.Count)"
    }

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(12, 460); $btnRefresh.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(582, 460); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null
    $btnRefresh.Add_Click({ Load-Grid })
    $btnClose.Add_Click({ $form.Close() })

    Load-Grid
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  STOCK (TRANSACTIONS) (Reports -> "Stock(Trans.)")
#  Har Purchase (IN) aur Rough Estimate Issue (OUT), sabhi products, ek hi
#  chronological list mein - Product filter se ek item par bhi focus kar
#  sakte hain.
# ============================================================================
function Show-StockTransForm {
    $script:AllProducts = Get-AllProducts
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Stock Transactions"
    $form.Size = New-Object System.Drawing.Size(920, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(920, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "STOCK TRANSACTIONS (IN / OUT)" 904))

    $lblProd = New-Object System.Windows.Forms.Label
    $lblProd.Text = "Product:"; $lblProd.Location = New-Object System.Drawing.Point(15, 52); $lblProd.AutoSize = $true
    $cboProduct = New-Object System.Windows.Forms.ComboBox
    $cboProduct.Location = New-Object System.Drawing.Point(80, 49); $cboProduct.Size = New-Object System.Drawing.Size(350, 22)
    $cboProduct.DropDownStyle = "DropDownList"
    $prodItems = New-Object System.Collections.ArrayList
    [void]$prodItems.Add("All Products")
    foreach ($p in $script:AllProducts) { [void]$prodItems.Add("$($p.Code) - $($p.Desc)") }
    $cboProduct.Items.AddRange($prodItems.ToArray())
    $cboProduct.SelectedIndex = 0
    $form.Controls.Add($lblProd) | Out-Null
    $form.Controls.Add($cboProduct) | Out-Null

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 84); $grid.Size = New-Object System.Drawing.Size(880, 400)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Date", "Date") | Out-Null
    $grid.Columns.Add("Code", "Product Code") | Out-Null
    $grid.Columns.Add("Desc", "Description") | Out-Null
    $grid.Columns.Add("Type", "Type") | Out-Null
    $grid.Columns.Add("Qty", "Qty") | Out-Null
    $grid.Columns.Add("RefNo", "Ref.No") | Out-Null
    $grid.Columns.Add("Party", "Party") | Out-Null
    $grid.Columns["Date"].Width = 90; $grid.Columns["Code"].Width = 90; $grid.Columns["Desc"].Width = 200
    $grid.Columns["Type"].Width = 100; $grid.Columns["Qty"].Width = 70; $grid.Columns["RefNo"].Width = 90; $grid.Columns["Party"].Width = 200
    $grid.Columns["Qty"].DefaultCellStyle.Alignment = "MiddleRight"
    $form.Controls.Add($grid)

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Location = New-Object System.Drawing.Point(12, 494); $lblCount.AutoSize = $true; $lblCount.Font = $FontNormal
    $lblCount.Anchor = "Bottom, Left"
    $form.Controls.Add($lblCount)

    function Load-Grid {
        $grid.Rows.Clear()
        $filterCode = ""
        if ($cboProduct.Text -ne "All Products" -and $cboProduct.Text.Trim() -ne "") {
            $filterCode = ($cboProduct.Text -split ' - ')[0].Trim()
        }
        foreach ($t in (Get-StockTransactions -FilterCode $filterCode)) {
            $grid.Rows.Add($t.Date.ToString("dd-MM-yyyy"), $t.Code, $t.Desc, $t.Type, $t.Qty, $t.RefNo, $t.Party) | Out-Null
        }
        $lblCount.Text = "Transaction(s): $($grid.Rows.Count)"
    }

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(12, 516); $btnRefresh.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(802, 516); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null
    $cboProduct.Add_SelectedIndexChanged({ Load-Grid })
    $btnRefresh.Add_Click({ Load-Grid })
    $btnClose.Add_Click({ $form.Close() })

    Load-Grid
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  STOCK LEDGER (Reports -> "Stock Ledger")
#  Ek product chuno -> Opening Qty se shuru karke har Purchase (+) aur Issue
#  (-) ke saath running balance - Party Ledger jaisa hi, bas Rupaye ki jagah
#  Qty ke saath.
# ============================================================================
function Show-StockLedgerForm {
    $script:AllProducts = Get-AllProducts
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Stock Ledger"
    $form.Size = New-Object System.Drawing.Size(900, 600)
    $form.MinimumSize = New-Object System.Drawing.Size(900, 600)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "STOCK LEDGER" 884))

    $lblProd = New-Object System.Windows.Forms.Label
    $lblProd.Text = "Product:"; $lblProd.Location = New-Object System.Drawing.Point(15, 52); $lblProd.AutoSize = $true
    $cboProduct = New-Object System.Windows.Forms.ComboBox
    $cboProduct.Location = New-Object System.Drawing.Point(80, 49); $cboProduct.Size = New-Object System.Drawing.Size(400, 22)
    $cboProduct.DropDownStyle = "DropDown"; $cboProduct.AutoCompleteMode = "SuggestAppend"; $cboProduct.AutoCompleteSource = "ListItems"
    $prodItems = New-Object System.Collections.ArrayList
    foreach ($p in $script:AllProducts) { [void]$prodItems.Add("$($p.Code) - $($p.Desc)") }
    $cboProduct.Items.AddRange($prodItems.ToArray())
    Enable-ComboBoxContainsSearch -Combo $cboProduct -GetAllItems { $prodItems.ToArray() }
    $btnShow = New-Object System.Windows.Forms.Button
    $btnShow.Text = "Show Ledger"; $btnShow.Font = $FontBold; $btnShow.Size = New-Object System.Drawing.Size(120, 26)
    $btnShow.Location = New-Object System.Drawing.Point(490, 48)
    $form.Controls.Add($lblProd) | Out-Null
    $form.Controls.Add($cboProduct) | Out-Null
    $form.Controls.Add($btnShow) | Out-Null

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 85); $grid.Size = New-Object System.Drawing.Size(860, 420)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Date", "Date") | Out-Null
    $grid.Columns.Add("RefNo", "Ref.No") | Out-Null
    $grid.Columns.Add("Particulars", "Particulars") | Out-Null
    $grid.Columns.Add("In", "In (+)") | Out-Null
    $grid.Columns.Add("Out", "Out (-)") | Out-Null
    $grid.Columns.Add("Balance", "Balance") | Out-Null
    $grid.Columns["Date"].Width = 90; $grid.Columns["RefNo"].Width = 90; $grid.Columns["Particulars"].Width = 320
    $grid.Columns["In"].Width = 90; $grid.Columns["Out"].Width = 90; $grid.Columns["Balance"].Width = 110
    $grid.Columns["In"].DefaultCellStyle.Alignment = "MiddleRight"
    $grid.Columns["Out"].DefaultCellStyle.Alignment = "MiddleRight"
    $grid.Columns["Balance"].DefaultCellStyle.Alignment = "MiddleRight"; $grid.Columns["Balance"].DefaultCellStyle.Font = $FontBold
    $form.Controls.Add($grid)

    $lblBalance = New-Object System.Windows.Forms.Label
    $lblBalance.Text = ""; $lblBalance.Font = $FontBold; $lblBalance.ForeColor = $ColorVfpBlue
    $lblBalance.AutoSize = $true; $lblBalance.Location = New-Object System.Drawing.Point(12, 514)
    $form.Controls.Add($lblBalance)

    function Load-StockLedger {
        $grid.Rows.Clear()
        $lblBalance.Text = ""
        if ($cboProduct.Text.Trim() -eq "") { return }
        $code = ($cboProduct.Text -split ' - ')[0].Trim()
        $opening = 0.0
        foreach ($o in (Read-JsonArray $StockOpeningFile)) {
            if ("$($o.Code)".Trim() -eq $code) { [double]::TryParse("$($o.Qty)", [ref]$opening) | Out-Null }
        }
        $grid.Rows.Add("", "", "Opening Qty", "", "", $opening) | Out-Null
        $bal = $opening
        foreach ($t in (Get-StockTransactions -FilterCode $code)) {
            $inQty = ""; $outQty = ""
            if ($t.Type -like "IN*") { $inQty = $t.Qty; $bal += $t.Qty }
            else { $outQty = $t.Qty; $bal -= $t.Qty }
            $particulars = "$($t.Type) - $($t.Party)"
            $grid.Rows.Add($t.Date.ToString("dd-MM-yyyy"), $t.RefNo, $particulars, $inQty, $outQty, $bal) | Out-Null
        }
        $lblBalance.Text = "Current Stock Balance: $bal"
    }

    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(782, 512); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnClose) | Out-Null

    $btnShow.Add_Click({ Load-StockLedger })
    $btnClose.Add_Click({ $form.Close() })

    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  AUDIT LOG VIEWER (Housekeeping -> "View Audit Log")
#  Shows every Create/Edit/Delete done in this software - who, when, what.
#  Newest entries on top; can be filtered by typing a customer/bill/product
#  name/code, or narrowed to just one Entity type (Bill / Customer / etc).
# ============================================================================
function Show-AuditLogForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Nav Durga Sports - Audit Log"
    $form.Size = New-Object System.Drawing.Size(920, 560)
    $form.MinimumSize = New-Object System.Drawing.Size(920, 560)
    $form.StartPosition = "CenterScreen"; $form.FormBorderStyle = "Sizable"; $form.MaximizeBox = $true
    $form.BackColor = [System.Drawing.SystemColors]::Control; $form.Font = $FontNormal
    $form.Controls.Add((New-TitleBanner "AUDIT LOG (KISNE KAB KYA BADLA)" 904))

    $lblFilter = New-Object System.Windows.Forms.Label
    $lblFilter.Text = "Search:"; $lblFilter.Location = New-Object System.Drawing.Point(15, 54); $lblFilter.AutoSize = $true
    $txtFilter = New-Object System.Windows.Forms.TextBox
    $txtFilter.Location = New-Object System.Drawing.Point(75, 51); $txtFilter.Size = New-Object System.Drawing.Size(260, 22)
    $lblType = New-Object System.Windows.Forms.Label
    $lblType.Text = "Type:"; $lblType.Location = New-Object System.Drawing.Point(350, 54); $lblType.AutoSize = $true
    $cboType = New-Object System.Windows.Forms.ComboBox
    $cboType.Location = New-Object System.Drawing.Point(395, 51); $cboType.Size = New-Object System.Drawing.Size(170, 22)
    $cboType.DropDownStyle = "DropDownList"
    $cboType.Items.AddRange(@("All", "Rough Estimate", "Customer", "Product", "Purchase Voucher", "Stock Opening"))
    $cboType.SelectedIndex = 0
    $form.Controls.Add($lblFilter) | Out-Null
    $form.Controls.Add($txtFilter) | Out-Null
    $form.Controls.Add($lblType) | Out-Null
    $form.Controls.Add($cboType) | Out-Null

    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = New-Object System.Drawing.Point(12, 84); $grid.Size = New-Object System.Drawing.Size(880, 400)
    $grid.Anchor = "Top, Bottom, Left, Right"
    Style-Grid $grid
    $grid.Columns.Add("Timestamp", "Date & Time") | Out-Null
    $grid.Columns.Add("User", "User") | Out-Null
    $grid.Columns.Add("Action", "Action") | Out-Null
    $grid.Columns.Add("Entity", "Type") | Out-Null
    $grid.Columns.Add("Details", "Details") | Out-Null
    $grid.Columns["Timestamp"].Width = 150; $grid.Columns["User"].Width = 100; $grid.Columns["Action"].Width = 80
    $grid.Columns["Entity"].Width = 140; $grid.Columns["Details"].Width = 380
    $form.Controls.Add($grid)

    $script:AuditLogData = @()
    function Load-AuditGrid {
        $grid.Rows.Clear()
        $all = @(Read-JsonArray $AuditLogFile)
        [array]::Reverse($all)
        $script:AuditLogData = $all
        $searchText = $txtFilter.Text.Trim().ToLower()
        $typeFilter = $cboType.Text
        $shown = 0
        foreach ($a in $script:AuditLogData) {
            if ($typeFilter -ne "All" -and "$($a.Entity)" -ne $typeFilter) { continue }
            if ($searchText -ne "" -and -not ("$($a.Details)".ToLower().Contains($searchText))) { continue }
            $grid.Rows.Add($a.Timestamp, $a.User, $a.Action, $a.Entity, $a.Details) | Out-Null
            $shown++
        }
        $lblCount.Text = "Entries shown: $shown   (Total: $($script:AuditLogData.Count))"
    }

    $lblCount = New-Object System.Windows.Forms.Label
    $lblCount.Text = ""
    $lblCount.Location = New-Object System.Drawing.Point(12, 494); $lblCount.AutoSize = $true
    $lblCount.Anchor = "Bottom, Left"
    $form.Controls.Add($lblCount) | Out-Null

    $btnRefresh = New-Object System.Windows.Forms.Button
    $btnRefresh.Text = "Refresh"; $btnRefresh.Font = $FontNormal; $btnRefresh.Size = New-Object System.Drawing.Size(90, 34)
    $btnRefresh.Location = New-Object System.Drawing.Point(12, 516); $btnRefresh.Anchor = "Bottom, Left"
    $btnBackupNow = New-Object System.Windows.Forms.Button
    $btnBackupNow.Text = "Backup Now"; $btnBackupNow.Font = $FontBold; $btnBackupNow.Size = New-Object System.Drawing.Size(130, 34)
    $btnBackupNow.Location = New-Object System.Drawing.Point(112, 516); $btnBackupNow.BackColor = [System.Drawing.Color]::FromArgb(210, 230, 210)
    $btnBackupNow.Anchor = "Bottom, Left"
    $btnClose = New-Object System.Windows.Forms.Button
    $btnClose.Text = "Close"; $btnClose.Font = $FontNormal; $btnClose.Size = New-Object System.Drawing.Size(90, 34)
    $btnClose.Location = New-Object System.Drawing.Point(802, 516); $btnClose.Anchor = "Bottom, Right"
    $form.Controls.Add($btnRefresh) | Out-Null
    $form.Controls.Add($btnBackupNow) | Out-Null
    $form.Controls.Add($btnClose) | Out-Null

    $txtFilter.Add_TextChanged({ Load-AuditGrid })
    $cboType.Add_SelectedIndexChanged({ Load-AuditGrid })
    $btnRefresh.Add_Click({ Load-AuditGrid })
    $btnBackupNow.Add_Click({ Backup-AppData })
    $btnClose.Add_Click({ $form.Close() })

    Load-AuditGrid
    $form.ShowDialog() | Out-Null
}

# ============================================================================
#  STARTUP SCREENS (2026-09-11): ek chhota decorative welcome/splash screen
#  (~2 second, koi function nahi - sirf achha dikhne ke liye), phir ek asli
#  Password Login screen (galat password se aage nahi jaa sakte). Dono
#  Vineet ke bheje gaye purane-software-jaise reference screenshots se
#  design kiye gaye hain.
# ============================================================================
function Show-SplashScreen {
    $splash = New-Object System.Windows.Forms.Form
    $splash.FormBorderStyle = "None"
    $splash.StartPosition = "CenterScreen"
    $splash.Size = New-Object System.Drawing.Size(560, 320)
    $splash.BackColor = [System.Drawing.Color]::FromArgb(255, 251, 235)
    $splash.ShowInTaskbar = $false

    $bandTop = New-Object System.Windows.Forms.Panel
    $bandTop.Dock = "Top"
    $bandTop.Height = 8
    $bandTop.BackColor = [System.Drawing.Color]::FromArgb(0, 0, 128)
    $splash.Controls.Add($bandTop)

    $bandBottom = New-Object System.Windows.Forms.Panel
    $bandBottom.Dock = "Bottom"
    $bandBottom.Height = 6
    $bandBottom.BackColor = [System.Drawing.Color]::FromArgb(255, 193, 7)
    $splash.Controls.Add($bandBottom)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "VANI, MEERUT"
    $lblTitle.Font = New-Object System.Drawing.Font("Tahoma", 28, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 0, 128)
    $lblTitle.AutoSize = $true
    $lblTitle.Location = New-Object System.Drawing.Point(60, 55)
    $splash.Controls.Add($lblTitle)

    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = "Cricket Tennis Balls"
    $lblSub.Font = New-Object System.Drawing.Font("Tahoma", 14, [System.Drawing.FontStyle]::Bold)
    $lblSub.ForeColor = [System.Drawing.Color]::FromArgb(230, 126, 0)
    $lblSub.AutoSize = $true
    $lblSub.Location = New-Object System.Drawing.Point(63, 105)
    $splash.Controls.Add($lblSub)

    $lblLoad = New-Object System.Windows.Forms.Label
    $lblLoad.Text = "Billing Software - Loading..."
    $lblLoad.Font = New-Object System.Drawing.Font("Tahoma", 10)
    $lblLoad.ForeColor = [System.Drawing.Color]::FromArgb(100, 100, 100)
    $lblLoad.AutoSize = $true
    $lblLoad.Location = New-Object System.Drawing.Point(63, 145)
    $splash.Controls.Add($lblLoad)

    $badgeDefs = @(
        @{ Letter = "P"; Color = [System.Drawing.Color]::FromArgb(30, 90, 200) },
        @{ Letter = "D"; Color = [System.Drawing.Color]::FromArgb(20, 150, 120) },
        @{ Letter = "E"; Color = [System.Drawing.Color]::FromArgb(230, 140, 20) },
        @{ Letter = "S"; Color = [System.Drawing.Color]::FromArgb(130, 60, 170) },
        @{ Letter = "B"; Color = [System.Drawing.Color]::FromArgb(40, 150, 60) },
        @{ Letter = "X"; Color = [System.Drawing.Color]::FromArgb(190, 40, 40) }
    )
    $bx = 60
    foreach ($bd in $badgeDefs) {
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Size = New-Object System.Drawing.Size(52, 52)
        $pic.Location = New-Object System.Drawing.Point($bx, 210)
        $pic.Tag = $bd
        $pic.Add_Paint({
            $info = $this.Tag
            $g = $_.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $brush = New-Object System.Drawing.SolidBrush($info.Color)
            $g.FillEllipse($brush, 0, 0, $this.Width - 1, $this.Height - 1)
            $fnt = New-Object System.Drawing.Font("Tahoma", 18, [System.Drawing.FontStyle]::Bold)
            $sf = New-Object System.Drawing.StringFormat
            $sf.Alignment = [System.Drawing.StringAlignment]::Center
            $sf.LineAlignment = [System.Drawing.StringAlignment]::Center
            $rect = New-Object System.Drawing.RectangleF(0, 0, $this.Width, $this.Height)
            $g.DrawString($info.Letter, $fnt, [System.Drawing.Brushes]::White, $rect, $sf)
        })
        $splash.Controls.Add($pic)
        $bx += 68
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1800
    $timer.Add_Tick({
        $timer.Stop()
        $splash.Close()
    })
    $splash.Add_Shown({ $timer.Start() })
    $splash.ShowDialog() | Out-Null
}

function Show-LoginScreen {
    $login = New-Object System.Windows.Forms.Form
    $login.Text = "User Login"
    $login.FormBorderStyle = "FixedDialog"
    $login.StartPosition = "CenterScreen"
    $login.Size = New-Object System.Drawing.Size(420, 260)
    $login.MaximizeBox = $false
    $login.MinimizeBox = $false
    $login.BackColor = [System.Drawing.Color]::White

    $band = New-Object System.Windows.Forms.Panel
    $band.Dock = "Top"
    $band.Height = 36
    $band.BackColor = [System.Drawing.Color]::FromArgb(128, 128, 64)
    $login.Controls.Add($band)
    $lblBand = New-Object System.Windows.Forms.Label
    $lblBand.Text = "  User Login"
    $lblBand.Font = $FontBold
    $lblBand.ForeColor = [System.Drawing.Color]::White
    $lblBand.Dock = "Fill"
    $lblBand.TextAlign = "MiddleLeft"
    $band.Controls.Add($lblBand)

    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = "User Name:"
    $lblUser.Font = $FontNormal
    $lblUser.AutoSize = $true
    $lblUser.Location = New-Object System.Drawing.Point(30, 75)
    $login.Controls.Add($lblUser)
    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Font = $FontNormal
    $txtUser.Text = "Vineet"
    $txtUser.Location = New-Object System.Drawing.Point(150, 72)
    $txtUser.Size = New-Object System.Drawing.Size(200, 24)
    $login.Controls.Add($txtUser)

    $lblPass = New-Object System.Windows.Forms.Label
    $lblPass.Text = "Password:"
    $lblPass.Font = $FontNormal
    $lblPass.AutoSize = $true
    $lblPass.Location = New-Object System.Drawing.Point(30, 115)
    $login.Controls.Add($lblPass)
    $txtPass = New-Object System.Windows.Forms.TextBox
    $txtPass.Font = $FontNormal
    $txtPass.Location = New-Object System.Drawing.Point(150, 112)
    $txtPass.Size = New-Object System.Drawing.Size(200, 24)
    $txtPass.PasswordChar = "*"
    $login.Controls.Add($txtPass)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "OK"
    $btnOk.Font = $FontBold
    $btnOk.Size = New-Object System.Drawing.Size(90, 32)
    $btnOk.Location = New-Object System.Drawing.Point(110, 170)
    $login.Controls.Add($btnOk)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancel Login"
    $btnCancel.Font = $FontBold
    $btnCancel.Size = New-Object System.Drawing.Size(120, 32)
    $btnCancel.Location = New-Object System.Drawing.Point(210, 170)
    $login.Controls.Add($btnCancel)

    $btnOk.Add_Click({
        if ($txtPass.Text -eq (Get-AppPassword)) {
            $login.DialogResult = [System.Windows.Forms.DialogResult]::OK
        } else {
            [System.Windows.Forms.MessageBox]::Show("Password galat hai, dobara try karein.", "User Login", "OK", "Warning") | Out-Null
            $txtPass.Text = ""
            $txtPass.Focus()
        }
    })
    $btnCancel.Add_Click({ $login.DialogResult = [System.Windows.Forms.DialogResult]::Cancel })
    $login.AcceptButton = $btnOk
    $login.Add_Shown({ $txtPass.Focus() })
    $result = $login.ShowDialog()
    return ($result -eq [System.Windows.Forms.DialogResult]::OK)
}

function Show-ChangePasswordForm {
    $frm = New-Object System.Windows.Forms.Form
    $frm.Text = "Change Password"
    $frm.FormBorderStyle = "FixedDialog"
    $frm.StartPosition = "CenterScreen"
    $frm.Size = New-Object System.Drawing.Size(380, 260)
    $frm.MaximizeBox = $false
    $frm.MinimizeBox = $false

    $lbl1 = New-Object System.Windows.Forms.Label
    $lbl1.Text = "Current Password:"
    $lbl1.Font = $FontNormal
    $lbl1.AutoSize = $true
    $lbl1.Location = New-Object System.Drawing.Point(20, 30)
    $frm.Controls.Add($lbl1)
    $txtCur = New-Object System.Windows.Forms.TextBox
    $txtCur.PasswordChar = "*"
    $txtCur.Font = $FontNormal
    $txtCur.Location = New-Object System.Drawing.Point(180, 27)
    $txtCur.Size = New-Object System.Drawing.Size(160, 24)
    $frm.Controls.Add($txtCur)

    $lbl2 = New-Object System.Windows.Forms.Label
    $lbl2.Text = "New Password:"
    $lbl2.Font = $FontNormal
    $lbl2.AutoSize = $true
    $lbl2.Location = New-Object System.Drawing.Point(20, 72)
    $frm.Controls.Add($lbl2)
    $txtNew = New-Object System.Windows.Forms.TextBox
    $txtNew.PasswordChar = "*"
    $txtNew.Font = $FontNormal
    $txtNew.Location = New-Object System.Drawing.Point(180, 69)
    $txtNew.Size = New-Object System.Drawing.Size(160, 24)
    $frm.Controls.Add($txtNew)

    $lbl3 = New-Object System.Windows.Forms.Label
    $lbl3.Text = "Confirm New Password:"
    $lbl3.Font = $FontNormal
    $lbl3.AutoSize = $true
    $lbl3.Location = New-Object System.Drawing.Point(20, 114)
    $frm.Controls.Add($lbl3)
    $txtConfirm = New-Object System.Windows.Forms.TextBox
    $txtConfirm.PasswordChar = "*"
    $txtConfirm.Font = $FontNormal
    $txtConfirm.Location = New-Object System.Drawing.Point(180, 111)
    $txtConfirm.Size = New-Object System.Drawing.Size(160, 24)
    $frm.Controls.Add($txtConfirm)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "Save"
    $btnSave.Font = $FontBold
    $btnSave.Size = New-Object System.Drawing.Size(100, 32)
    $btnSave.Location = New-Object System.Drawing.Point(80, 165)
    $frm.Controls.Add($btnSave)

    $btnCancel2 = New-Object System.Windows.Forms.Button
    $btnCancel2.Text = "Cancel"
    $btnCancel2.Font = $FontBold
    $btnCancel2.Size = New-Object System.Drawing.Size(100, 32)
    $btnCancel2.Location = New-Object System.Drawing.Point(195, 165)
    $frm.Controls.Add($btnCancel2)

    $btnSave.Add_Click({
        if ($txtCur.Text -ne (Get-AppPassword)) {
            [System.Windows.Forms.MessageBox]::Show("Current password galat hai.", "Change Password", "OK", "Warning") | Out-Null
            return
        }
        if ("$($txtNew.Text)".Trim() -eq "") {
            [System.Windows.Forms.MessageBox]::Show("Naya password khali nahi ho sakta.", "Change Password", "OK", "Warning") | Out-Null
            return
        }
        if ($txtNew.Text -ne $txtConfirm.Text) {
            [System.Windows.Forms.MessageBox]::Show("Naya password aur Confirm password match nahi kar rahe.", "Change Password", "OK", "Warning") | Out-Null
            return
        }
        Set-AppPassword -NewPassword $txtNew.Text
        [System.Windows.Forms.MessageBox]::Show("Password badal diya gaya hai.", "Change Password", "OK", "Information") | Out-Null
        $frm.DialogResult = [System.Windows.Forms.DialogResult]::OK
    })
    $btnCancel2.Add_Click({ $frm.DialogResult = [System.Windows.Forms.DialogResult]::Cancel })
    $frm.AcceptButton = $btnSave
    $frm.ShowDialog() | Out-Null
}

# ============================================================================
#  MAIN MENU - mirrors the old software's own structure exactly:
#  Master / Data Entry / Reports / Lists / Housekeeping (from Vineet's own
#  screenshots of the real old system, 2026-09-05). Items that are actually
#  built open the real screen; items not built yet show a clear "coming
#  soon" message instead of doing nothing or erroring, so the full menu can
#  be seen/opened right away while screens are added one at a time.
# ============================================================================
function Invoke-Safe {
    param([scriptblock]$Action)
    try { & $Action }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Error aaya:`n`n$($_.Exception.Message)`n`nLine: $($_.InvocationInfo.ScriptLineNumber)", "Nav Durga Sports - Error", "OK", "Error") | Out-Null
    }
}

function Invoke-MenuItem {
    param([string]$ItemText)
    switch ($ItemText) {
        "Product Master"        { Invoke-Safe { Show-ProductMasterForm } }
        "Customer Master"       { Invoke-Safe { Show-CustomerMasterForm } }
        "Group Master"          { Invoke-Safe { Show-SimpleMasterForm -Title "Group Master" -DataFile $GroupMasterFile -ItemLabel "Group Name" } }
        "Unit Master"           { Invoke-Safe { Show-SimpleMasterForm -Title "Unit Master" -DataFile $UnitMasterFile -ItemLabel "Unit Name" } }
        "State Master"          { Invoke-Safe { Show-SimpleMasterForm -Title "State Master" -DataFile $StateMasterFile -ItemLabel "State Name" } }
        "GST Master"            { Invoke-Safe { Show-SimpleMasterForm -Title "GST Master" -DataFile $GstMasterFile -ItemLabel "GST Rate (%)" } }
        "Product List"          { Invoke-Safe { Show-ProductListReportForm } }
        "Cash Recd. Voucher"    { Invoke-Safe { Show-CashReceiptListForm } }
        "Cash Payment Voucher"  { Invoke-Safe { Show-CashPaymentListForm } }
        "Rough Estimate"        { Invoke-Safe { Show-BillListForm } }
        "Customer Account Copy" { Invoke-Safe { Show-LedgerForm } }
        "Customer Statement (Date Range)" { Invoke-Safe { Show-CustomerStatementForm } }
        "Rough Estimate Register" { Invoke-Safe { Show-RoughEstimateRegisterForm } }
        "Bill List (History)"   { Invoke-Safe { Show-BillListForm } }
        "Purchase Voucher"      { Invoke-Safe { Show-PurchaseVoucherListForm } }
        "Stock"                 { Invoke-Safe { Show-StockSummaryForm } }
        "Trial Balance"         { Invoke-Safe { Show-TrialBalanceForm } }
        "Outstanding / Udhari List" { Invoke-Safe { Show-OutstandingListForm } }
        "Cash Day Book"         { Invoke-Safe { Show-CashDayBookForm } }
        "Journal Day Book"      { Invoke-Safe { Show-JournalDayBookForm } }
        "Stock(Group)"          { Invoke-Safe { Show-StockGroupForm } }
        "Stock(Trans.)"         { Invoke-Safe { Show-StockTransForm } }
        "Stock Ledger"          { Invoke-Safe { Show-StockLedgerForm } }
        "Backup Now"            { Invoke-Safe { Backup-AppData } }
        "View Audit Log"        { Invoke-Safe { Show-AuditLogForm } }
        "Change Password"       { Invoke-Safe { Show-ChangePasswordForm } }
        "Exit"                  { $menu.Close() }
        default {
            [System.Windows.Forms.MessageBox]::Show("`"$ItemText`" abhi is software mein nahi bana hai - yeh jald add kiya jayega.", "Vani, Meerut", "OK", "Information") | Out-Null
        }
    }
}

$menu = New-Object System.Windows.Forms.Form
$menu.Text = "Nav Durga Sports - Billing Software"
$menu.Size = New-Object System.Drawing.Size(500, 640)
$menu.MinimumSize = New-Object System.Drawing.Size(500, 640)
$menu.StartPosition = "CenterScreen"
$menu.FormBorderStyle = "Sizable"
$menu.MaximizeBox = $true
$menu.BackColor = [System.Drawing.SystemColors]::Control
$menu.Font = $FontNormal
$menu.Controls.Add((New-TitleBanner "VANI, MEERUT" 484))

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "DASH X - Cricket Tennis Balls"
$lblSub.Font = $FontBold
$lblSub.ForeColor = $ColorVfpBlue
$lblSub.AutoSize = $true
$lblSub.Location = New-Object System.Drawing.Point(15, 50)
$menu.Controls.Add($lblSub)

$script:MenuCategories = [ordered]@{
    "Master"       = @("Group Master", "Unit Master", "GST Master", "State Master", "Product Master", "Customer Master", "General Ledger")
    "Data Entry"   = @("Rough Estimate", "Cash Recd. Voucher", "Cash Payment Voucher", "Journal Voucher", "Purchase Voucher")
    "Reports"      = @("Customer Account Copy", "Customer Statement (Date Range)", "Rough Estimate Register", "Trial Balance", "Outstanding / Udhari List", "Cash Day Book", "Journal Day Book", "Stock", "Stock(Group)", "Stock(Trans.)", "Stock Ledger", "Bill List (History)")
    "Lists"        = @("Product List")
    "Housekeeping" = @("Backup Now", "View Audit Log", "Change Password", "Company Statement", "Exit")
}

$ColorOliveDark  = [System.Drawing.Color]::FromArgb(128, 128, 64)
$ColorOliveLight = [System.Drawing.Color]::FromArgb(222, 222, 158)

# Category colour palette - richer/varied look (session 14 visual refresh)
$script:CatPalette = @{
    "Master"       = @{ Light = [System.Drawing.Color]::FromArgb(210, 225, 250); Dark = [System.Drawing.Color]::FromArgb(30, 90, 170) }
    "Data Entry"   = @{ Light = [System.Drawing.Color]::FromArgb(210, 240, 215); Dark = [System.Drawing.Color]::FromArgb(40, 140, 70) }
    "Reports"      = @{ Light = [System.Drawing.Color]::FromArgb(250, 225, 195); Dark = [System.Drawing.Color]::FromArgb(200, 110, 20) }
    "Lists"        = @{ Light = [System.Drawing.Color]::FromArgb(230, 215, 245); Dark = [System.Drawing.Color]::FromArgb(110, 60, 160) }
    "Housekeeping" = @{ Light = [System.Drawing.Color]::FromArgb(245, 215, 215); Dark = [System.Drawing.Color]::FromArgb(160, 40, 40) }
}

# Gold accent strip under the title banner - small touch of colour/richness
$accentStrip = New-Object System.Windows.Forms.Panel
$accentStrip.Location = New-Object System.Drawing.Point(0, 40)
$accentStrip.Size = New-Object System.Drawing.Size(484, 4)
$accentStrip.Anchor = "Top, Left, Right"
$accentStrip.BackColor = [System.Drawing.Color]::FromArgb(255, 193, 7)
$menu.Controls.Add($accentStrip)

# Left sidebar (category navigation) - stacked vertically like the old
# software's own menu. Reverted 2026-09-11 (Vineet didn't like the plain
# tree view's cut-off text and flat black/white look) back to this
# colorful button-panel design, now with a small icon in front of every
# category and every item too.
$script:CatIcons = @{
    "Master" = [char]0x2605; "Data Entry" = [char]0x270E; "Reports" = [char]0x25A6
    "Lists" = [char]0x2630; "Housekeeping" = [char]0x2699
}
$script:ItemBullet = [char]0x25CF

$catPanel = New-Object System.Windows.Forms.Panel
$catPanel.Location = New-Object System.Drawing.Point(12, 82)
$catPanel.Size = New-Object System.Drawing.Size(150, 472)
$catPanel.Anchor = "Top, Bottom, Left"
$catPanel.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 250)
$catPanel.BorderStyle = "FixedSingle"
$menu.Controls.Add($catPanel)

$itemsPanel = New-Object System.Windows.Forms.Panel
$itemsPanel.Location = New-Object System.Drawing.Point(168, 82)
$itemsPanel.Size = New-Object System.Drawing.Size(304, 472)
$itemsPanel.AutoScroll = $true
$itemsPanel.BorderStyle = "FixedSingle"
$itemsPanel.BackColor = [System.Drawing.Color]::White
$itemsPanel.Anchor = "Top, Bottom, Left, Right"
$menu.Controls.Add($itemsPanel)

$script:CatButtons = @{}
function Show-MenuCategory {
    param([string]$CatName)
    $itemsPanel.Controls.Clear()
    $y = 8
    $palette = $script:CatPalette[$CatName]
    foreach ($it in $script:MenuCategories[$CatName]) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = "  $($script:ItemBullet)   $it"
        $b.Tag = $it
        $b.Font = $FontBold
        $btnWidth = [Math]::Max(300, $itemsPanel.ClientSize.Width - 16)
        $b.Size = New-Object System.Drawing.Size($btnWidth, 38)
        $b.Location = New-Object System.Drawing.Point(8, $y)
        $b.Anchor = "Top, Left, Right"
        $b.FlatStyle = "Flat"
        $b.FlatAppearance.BorderSize = 1
        $b.FlatAppearance.BorderColor = $palette.Light
        $b.FlatAppearance.MouseOverBackColor = $palette.Light
        $b.TextAlign = "MiddleLeft"
        $b.Padding = New-Object System.Windows.Forms.Padding(12, 0, 0, 0)
        $b.BackColor = [System.Drawing.Color]::White
        $b.ForeColor = $palette.Dark
        $b.Add_Click({ Invoke-MenuItem $this.Tag })
        $itemsPanel.Controls.Add($b)
        $y += 44
    }
    foreach ($cn2 in @($script:CatButtons.Keys)) {
        $p2 = $script:CatPalette[$cn2]
        $script:CatButtons[$cn2].BackColor = $p2.Light
        $script:CatButtons[$cn2].ForeColor = $p2.Dark
    }
    if ($script:CatButtons.ContainsKey($CatName)) {
        $script:CatButtons[$CatName].BackColor = $palette.Dark
        $script:CatButtons[$CatName].ForeColor = [System.Drawing.Color]::White
    }
}

$catNames = @($script:MenuCategories.Keys)
$catBtnHeight = 52
$cy = 4
foreach ($cn in $catNames) {
    $cb = New-Object System.Windows.Forms.Button
    $cb.Text = "$($script:CatIcons[$cn])  $cn"
    $cb.Tag = $cn
    $cb.Font = $FontMenu
    $cb.Size = New-Object System.Drawing.Size(140, ($catBtnHeight - 4))
    $cb.Location = New-Object System.Drawing.Point(4, $cy)
    $cb.Anchor = "Top, Left, Right"
    $cb.FlatStyle = "Flat"
    $cb.FlatAppearance.BorderSize = 0
    $cb.TextAlign = "MiddleCenter"
    $cb.BackColor = $script:CatPalette[$cn].Light
    $cb.ForeColor = $script:CatPalette[$cn].Dark
    $cb.Add_Click({ Show-MenuCategory $this.Tag })
    $catPanel.Controls.Add($cb)
    $script:CatButtons[$cn] = $cb
    $cy += $catBtnHeight
}

# Status bar - Company / Year / Date, like the old software's bottom info strip
$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Location = New-Object System.Drawing.Point(0, 558)
$statusPanel.Size = New-Object System.Drawing.Size(484, 26)
$statusPanel.Anchor = "Bottom, Left, Right"
$statusPanel.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$statusPanel.BorderStyle = "FixedSingle"
$menu.Controls.Add($statusPanel)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Company: Vineet (001)     Year: 01/04/2025 - 31/03/2026     $(Get-Date -Format 'dd MMMM yyyy')"
$lblStatus.Font = $FontNormal
$lblStatus.AutoSize = $true
$lblStatus.Location = New-Object System.Drawing.Point(8, 5)
$statusPanel.Controls.Add($lblStatus)

Show-MenuCategory "Master"

# Open maximized (full screen), centered, and grab focus so the app is
# immediately clickable without the user having to click it first.
$menu.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
$menu.Add_Shown({
    $menu.Activate()
    $menu.BringToFront()
    $menu.Focus() | Out-Null
})
$menu.Add_FormClosing({ Stop-WhatsAppDaemonIfWeStartedIt })

# 2026-09-11 (session 21): F4 shortcut - Customer List seedha khulne ke
# liye, bina menu mein click kiye (jaldi kaam ke liye). F3 nahi use kiya
# kyunki Sales Bill Entry ke andar F3 pehle se "Save" hai.
$menu.KeyPreview = $true
$menu.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq 'F4') {
        Invoke-MenuItem "Customer Master"
        $e.Handled = $true; $e.SuppressKeyPress = $true
    }
})

try {
    Show-SplashScreen
    if (-not (Show-LoginScreen)) {
        exit
    }
    [System.Windows.Forms.Application]::Run($menu)
}
catch {
    [System.Windows.Forms.MessageBox]::Show("Ek unexpected error aaya:`n`n$($_.Exception.Message)`n`nLine: $($_.InvocationInfo.ScriptLineNumber)", "Nav Durga Sports - Error", "OK", "Error") | Out-Null
}
