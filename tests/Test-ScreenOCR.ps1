<#
  Renders terminal-style commands in different fonts, sizes and colour schemes,
  runs them through ScreenOCR and reports how much comes back exactly right.

  powershell -STA -ExecutionPolicy Bypass -File tests\Test-ScreenOCR.ps1 [-ShowFailures]
#>
param([switch]$ShowFailures, [string]$OutDir)

. "$PSScriptRoot\..\ScreenOCR.ps1"

$commands = @(
    'ls -la /etc/nginx'
    'sudo apt-get install -y python3-pip'
    'grep -rn "TODO" ./src | wc -l'
    'docker run -d -p 8080:80 --name web nginx:1.25'
    'kubectl get pods -n kube-system -o wide'
    'git log --oneline -n 10'
    'ssh -i ~/.ssh/id_ed25519 root@10.0.0.12 -p 2222'
    'curl -fsSL https://example.com/install.sh | bash'
    "find . -name '*.log' -mtime +7 -delete"
    'echo $HOME && export PATH=$PATH:/usr/local/bin'
    "awk '{print `$1}' access.log | sort | uniq -c | sort -rn | head"
    'chmod 755 script.sh; ./script.sh --verbose'
    'tar -xzvf archive-v1.2.0.tar.gz -C /opt/'
    'systemctl restart nginx.service'
    'sudo ufw allow from 192.168.1.0/24 to any port 22'
    'python3 -m venv .venv && source .venv/bin/activate'
    'npm install --save-dev @types/node'
    "sed -i 's/foo/bar/g' config.yaml"
    'cat /var/log/syslog | tail -n 100 > out.txt 2>&1'
    'psql -U postgres -h localhost -c "SELECT 1;"'
    'Get-ChildItem C:\Users\Admin -Recurse | Where-Object {$_.Length -gt 1MB}'
    'export API_KEY=a1B2c3D4e5F6g7H8i9J0'
    'sha256sum: 9f86d081884c7d659a2feaa0c55ad015'
    'id: 3f2504e0-4f89-11d3-9a0c-0305e82c3301'
    'yassine@box:~/projects$ make build'
    'docker exec -it db mysql -uroot -p"P@ss_w0rd!"'
    'rsync -avz --exclude=".git" ./ user@host:/srv/app/'
    'kill -9 $(lsof -t -i:3000)'
    'echo "line1\nline2" >> notes.txt'
    'if [ -f ~/.bashrc ]; then . ~/.bashrc; fi'
    'pip install "fastapi[all]>=0.110,<1.0"'
    'crontab -e  # 0 3 * * * /usr/bin/backup.sh'
    'ip addr show eth0 | grep inet'
    'journalctl -u nginx --since "1 hour ago" -f'
)

# name, font, size(pt), foreground, background
$styles = @(
    ,@('WinTerminal Cascadia 12', 'Cascadia Mono', 12, '#CCCCCC', '#0C0C0C')
    ,@('Consolas 11 grey',        'Consolas',      11, '#DCDCDC', '#0C0C0C')
    ,@('Consolas 10 green',       'Consolas',      10, '#13A10E', '#0C0C0C')
    ,@('Ubuntu Mono 12',          'Ubuntu Mono',   12, '#FFFFFF', '#300A24')
    ,@('PowerShell blue',         'Lucida Console',10, '#EEEDF0', '#012456')
    ,@('Solarized dark',          'Cascadia Mono', 11, '#839496', '#002B36')
    ,@('Dracula 14',              'Consolas',      14, '#F8F8F2', '#282A36')
    ,@('Light Courier 12',        'Courier New',   12, '#000000', '#FFFFFF')
    ,@('Small Cascadia 9',        'Cascadia Mono',  9, '#CCCCCC', '#1E1E1E')
)

function New-TermImage([string[]]$lines, $style) {
    $font = New-Object System.Drawing.Font $style[1], $style[2]
    $fg = [System.Drawing.ColorTranslator]::FromHtml($style[3])
    $bg = [System.Drawing.ColorTranslator]::FromHtml($style[4])
    $lineH = [int]($font.GetHeight() * 1.15)
    $probe = [System.Windows.Forms.TextRenderer]::MeasureText(($lines | Sort-Object Length | Select-Object -Last 1), $font)
    $bmp = New-Object System.Drawing.Bitmap ($probe.Width + 30), ($lineH * $lines.Count + 16)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear($bg)
    $y = 8
    foreach ($l in $lines) {
        [System.Windows.Forms.TextRenderer]::DrawText($g, $l, $font, (New-Object System.Drawing.Point 8, $y), $fg, $bg)
        $y += $lineH
    }
    $g.Dispose(); $font.Dispose()
    $bmp
}

function Get-EditDistance([string]$a, [string]$b) {
    $prev = 0..$b.Length
    for ($i = 1; $i -le $a.Length; $i++) {
        $cur = @($i) + (1..[Math]::Max(1, $b.Length) | ForEach-Object { 0 })
        for ($j = 1; $j -le $b.Length; $j++) {
            $cost = [int]($a[$i - 1] -cne $b[$j - 1])
            $cur[$j] = [Math]::Min([Math]::Min($prev[$j] + 1, $cur[$j - 1] + 1), $prev[$j - 1] + $cost)
        }
        $prev = $cur
    }
    $prev[$b.Length]
}

function Compare-Line([string]$expected, [string]$got) {
    $e = ($expected -replace '\s+', ' ').Trim()
    $g = ($got -replace '\s+', ' ').Trim()
    [pscustomobject]@{ Expected = $e; Got = $g; Exact = $e -ceq $g; Errors = Get-EditDistance $e $g; Chars = $e.Length }
}

$all = @()
foreach ($style in $styles) {
    # Single-command grabs: the main use case
    $rows = foreach ($cmd in $commands) {
        $bmp = New-TermImage @($cmd) $style
        $got = (Get-OcrText $bmp) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1
        $bmp.Dispose()
        Compare-Line $cmd ([string]$got)
    }
    $exact = @($rows | Where-Object Exact).Count
    $errs = ($rows | Measure-Object Errors -Sum).Sum
    $chars = ($rows | Measure-Object Chars -Sum).Sum
    '{0,-26} exact {1,2}/{2}   char accuracy {3:P1}' -f $style[0], $exact, $rows.Count, (1 - $errs / $chars)
    if ($ShowFailures) {
        foreach ($r in $rows | Where-Object { -not $_.Exact }) { "    want: $($r.Expected)"; "    got:  $($r.Got)" }
    }
    $all += $rows | ForEach-Object { $_ | Add-Member -NotePropertyName Style -NotePropertyValue $style[0] -PassThru }
}

$exact = @($all | Where-Object Exact).Count
'{0,-26} exact {1}/{2} ({3:P0})   char accuracy {4:P1}' -f 'TOTAL', $exact, $all.Count, ($exact / $all.Count), (1 - ($all | Measure-Object Errors -Sum).Sum / ($all | Measure-Object Chars -Sum).Sum)
if ($OutDir) { $all | Export-Csv (Join-Path $OutDir 'results.csv') -NoTypeInformation }
