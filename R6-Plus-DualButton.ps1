# R6 (:+ customer WPF application
$ErrorActionPreference = 'Stop'

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $arguments = @('-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments
    exit
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

if (-not ('R6MouseApi' -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
public static class R6MouseApi {
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    public static bool IsDown(int key) { return (GetAsyncKeyState(key) & 0x8000) != 0; }
}

public static class R6MotionEngine {
    public static double DownSpeed = 5.0;
    public static double SideSpeed = 0.0;
    private static volatile bool running;
    private static Thread worker;
    private static readonly object gate = new object();

    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);

    public static void Start() {
        lock (gate) {
            if (running) return;
            running = true;
            worker = new Thread(Loop);
            worker.IsBackground = true;
            worker.Priority = ThreadPriority.AboveNormal;
            worker.Start();
        }
    }

    public static void Stop() {
        lock (gate) { running = false; }
    }

    private static void Loop() {
        bool rightArmed = false;
        bool moving = false;
        double downCarry = 0.0;
        double sideCarry = 0.0;

        while (running) {
            bool leftDown = R6MouseApi.IsDown(0x01);
            bool rightDown = R6MouseApi.IsDown(0x02);

            if (!moving) {
                if (rightDown && !leftDown) rightArmed = true;
                if (!rightDown && !leftDown) rightArmed = false;
                if (rightArmed && rightDown && leftDown) {
                    moving = true;
                    downCarry = 0.0;
                    sideCarry = 0.0;
                }
            } else if (!leftDown) {
                moving = false;
                rightArmed = rightDown;
                downCarry = 0.0;
                sideCarry = 0.0;
            } else if (rightDown) {
                downCarry += (150.0 * DownSpeed) * 0.008;
                sideCarry += (150.0 * SideSpeed) * 0.008;

                int deltaY = (int)Math.Floor(downCarry);
                int deltaX = (int)sideCarry;
                if (deltaY >= 1 || deltaX != 0) {
                    if (deltaY > 0) downCarry -= deltaY;
                    sideCarry -= deltaX;

                    R6MouseApi.POINT point;
                    R6MouseApi.GetCursorPos(out point);
                    int left = GetSystemMetrics(76);
                    int top = GetSystemMetrics(77);
                    int right = left + GetSystemMetrics(78) - 1;
                    int bottom = top + GetSystemMetrics(79) - 1;
                    int newX = Math.Max(left, Math.Min(right, point.X + deltaX));
                    int newY = Math.Max(top, Math.Min(bottom, point.Y + deltaY));
                    R6MouseApi.SetCursorPos(newX, newY);
                }
            }

            Thread.Sleep(8);
        }
    }
}
'@
}

$warmupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="R6 (:+" Width="390" Height="190" WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ShowInTaskbar="True" Topmost="True">
  <Border Background="#09080B" BorderBrush="#9B63BE" BorderThickness="1" CornerRadius="16" Padding="28">
    <StackPanel VerticalAlignment="Center">
      <TextBlock Text="R6 (:+" Foreground="#B982DB" FontFamily="Segoe UI" FontSize="27" FontWeight="Bold"/>
      <TextBlock Text="STARTING APPLICATION" Foreground="#D8B6F0" FontFamily="Segoe UI" FontSize="11" FontWeight="Bold" Margin="1,12,0,0"/>
      <ProgressBar Height="4" IsIndeterminate="True" Foreground="#9B63BE" Background="#211728" Margin="0,18,0,0"/>
    </StackPanel>
  </Border>
</Window>
'@
$warmupReader = New-Object System.Xml.XmlNodeReader ([xml]$warmupXaml)
$warmupWindow = [Windows.Markup.XamlReader]::Load($warmupReader)
$warmupWindow.Show()
$warmupWindow.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)

if (-not ('WpfPlusLicenseManager' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;
using System.Security.Cryptography;

public static class WpfPlusLicenseManager
{
    private const string PublicKeyXml = @"<RSAKeyValue><Modulus>xjp09e3zwDdAGHVk7YBE1rCXFICa1oyNy79cDwxUbKC5p0Q8rMbPgwQTut3THQA5POeO3awcMAF4mNzkd2JGoXXtmy6k1ZQFITlO4LXUaBvM7SNy8pfDYtu7N92nhWNNh5ODEKstF18WNHMiJRNeL4iH9e3GnUJp596irrGPu4TBKqcka+oFibbKaD3IJxkIMpvrN8BryXiJpriwKk9dy192ydxpXvF98NMZDLu/OF3vX0wLtuFHjFp/9GkX5G61FnDk9IZVvZrg7TgRbXnXJFT6Mi5snuPQgbd1iqL2Y4a6N9MPWKPd3mcvJekevH4RPcaFa4jLuQCoTATXdrFCsQ==</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>";
    public static string ActiveLicenseId = "";
    public static string ActiveCustomerName = "";
    public static string ActiveSerial = "";

    public static string LicenseFilePath {
        get { return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "R6-Plus", "license.dat"); }
    }

    public static string RevocationManifestUrl = "";

    public static string LocalRevocationManifestPath {
        get {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Codex", "R6-Owner-Data", "revoked-licenses.r6r");
        }
    }

    public static string LocalDeletedLicenseIdsPath {
        get {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Codex", "R6-Owner-Data", "deleted-license-ids.txt");
        }
    }

    public static bool Verify(string customerName, string serial, out string message)
    {
        try {
            string normalizedName = (customerName ?? "").Trim().ToUpperInvariant();
            if (normalizedName.Length < 2) { message = "Enter the customer name used when the serial was created."; return false; }
            serial = RemoveWhitespace(serial);
            string[] parts = serial.Split('.');
            if (parts.Length != 3 || parts[0] != "R6") { message = "The serial format is not valid."; return false; }
            byte[] payload = FromBase64Url(parts[1]);
            byte[] signature = FromBase64Url(parts[2]);
            using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider()) {
                rsa.PersistKeyInCsp = false;
                rsa.FromXmlString(PublicKeyXml);
                if (!rsa.VerifyData(payload, CryptoConfig.MapNameToOID("SHA256"), signature)) {
                    message = "The serial signature is not valid."; return false;
                }
            }
            string[] fields = Encoding.UTF8.GetString(payload).Split('|');
            if (fields.Length != 4 || fields[0] != "R6P1") { message = "This key is not for the Plus version."; return false; }
            string licensedName = Encoding.UTF8.GetString(FromBase64Url(fields[1]));
            if (!string.Equals(licensedName, normalizedName, StringComparison.Ordinal)) {
                message = "This serial was issued to a different customer name."; return false;
            }
            ActiveLicenseId = fields[2];
            ActiveCustomerName = customerName.Trim();
            ActiveSerial = serial;
            if (IsRevoked(ActiveLicenseId, out message)) return false;
            message = "License verified.";
            return true;
        } catch { message = "The name or serial could not be verified."; return false; }
    }

    public static bool CheckCurrentLicense(out string message)
    {
        if (string.IsNullOrWhiteSpace(ActiveCustomerName) || string.IsNullOrWhiteSpace(ActiveSerial)) {
            message = "The active license could not be identified.";
            return false;
        }
        return Verify(ActiveCustomerName, ActiveSerial, out message);
    }

    private static bool IsRevoked(string licenseId, out string message)
    {
        message = "";
        string manifest = null;
        bool remoteConfigured = !string.IsNullOrWhiteSpace(RevocationManifestUrl);

        try {
            if (remoteConfigured) {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(RevocationManifestUrl);
                request.Method = "GET";
                request.Timeout = 5000;
                request.ReadWriteTimeout = 5000;
                using (WebResponse response = request.GetResponse())
                using (Stream stream = response.GetResponseStream())
                using (StreamReader reader = new StreamReader(stream, Encoding.UTF8)) {
                    manifest = reader.ReadToEnd();
                }
            } else if (File.Exists(LocalRevocationManifestPath)) {
                manifest = File.ReadAllText(LocalRevocationManifestPath, Encoding.UTF8);
            } else if (File.Exists(LocalDeletedLicenseIdsPath)) {
                foreach (string line in File.ReadAllLines(LocalDeletedLicenseIdsPath, Encoding.UTF8)) {
                    if (string.Equals((line ?? "").Trim(), licenseId, StringComparison.OrdinalIgnoreCase)) {
                        message = "This license has been revoked by the owner.";
                        return true;
                    }
                }
                return false;
            } else {
                return false;
            }
        } catch {
            if (remoteConfigured) {
                message = "The license revocation status could not be verified.";
                return true;
            }
            return false;
        }

        try {
            string[] parts = RemoveWhitespace(manifest).Split('.');
            if (parts.Length != 3 || parts[0] != "R6R") {
                message = "The license revocation manifest is invalid.";
                return true;
            }
            byte[] payload = FromBase64Url(parts[1]);
            byte[] signature = FromBase64Url(parts[2]);
            using (RSACryptoServiceProvider rsa = new RSACryptoServiceProvider()) {
                rsa.PersistKeyInCsp = false;
                rsa.FromXmlString(PublicKeyXml);
                if (!rsa.VerifyData(payload, CryptoConfig.MapNameToOID("SHA256"), signature)) {
                    message = "The license revocation manifest signature is invalid.";
                    return true;
                }
            }
            string[] fields = Encoding.UTF8.GetString(payload).Split('|');
            if (fields.Length != 3 || fields[0] != "R6R1") {
                message = "The license revocation manifest is invalid.";
                return true;
            }
            foreach (string revokedId in (fields[2] ?? "").Split(',')) {
                if (string.Equals(revokedId.Trim(), licenseId, StringComparison.OrdinalIgnoreCase)) {
                    message = "This license has been revoked by the owner.";
                    return true;
                }
            }
            return false;
        } catch {
            message = "The license revocation manifest is invalid.";
            return true;
        }
    }

    public static void Save(string customerName, string serial)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(LicenseFilePath));
        string encodedName = Convert.ToBase64String(Encoding.UTF8.GetBytes(customerName.Trim()));
        File.WriteAllText(LicenseFilePath, encodedName + Environment.NewLine + RemoveWhitespace(serial), Encoding.UTF8);
    }

    public static bool TryLoad(out string customerName, out string serial)
    {
        customerName = ""; serial = "";
        try {
            if (!File.Exists(LicenseFilePath)) return false;
            string[] lines = File.ReadAllLines(LicenseFilePath, Encoding.UTF8);
            if (lines.Length < 2) return false;
            customerName = Encoding.UTF8.GetString(Convert.FromBase64String(lines[0]));
            serial = lines[1];
            string ignored;
            return Verify(customerName, serial, out ignored);
        } catch { return false; }
    }

    private static string RemoveWhitespace(string value)
    {
        if (value == null) return "";
        StringBuilder result = new StringBuilder();
        foreach (char character in value) if (!char.IsWhiteSpace(character)) result.Append(character);
        return result.ToString();
    }

    private static byte[] FromBase64Url(string value)
    {
        string base64 = value.Replace('-', '+').Replace('_', '/');
        switch (base64.Length % 4) { case 2: base64 += "=="; break; case 3: base64 += "="; break; }
        return Convert.FromBase64String(base64);
    }
}
'@
}

# Optional for distributed customers: publish the owner's signed
# revoked-licenses.r6r file at an HTTPS URL and put that URL here. When this
# is blank, the app checks the local owner-data folder automatically.
$revocationManifestUrl = ''
[WpfPlusLicenseManager]::RevocationManifestUrl = $revocationManifestUrl

function Show-ActivationWindow {
    $activationXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="R6 (:+ Sign in" Width="520" Height="500" MinWidth="460" MinHeight="440"
        WindowStartupLocation="CenterScreen" ResizeMode="CanResizeWithGrip"
        Background="#09080B" Foreground="#D8B6F0" FontFamily="Segoe UI">
  <Grid Margin="30">
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
    <StackPanel>
      <TextBlock Text="R6 (:+" FontSize="30" FontWeight="Bold" Foreground="#B982DB"/>
      <TextBlock Text="CUSTOMER SIGN IN" FontSize="10" FontWeight="Bold" Foreground="#B993D0" Margin="2,5,0,0"/>
    </StackPanel>
    <Border Grid.Row="1" Background="#111014" BorderBrush="#3D2948" BorderThickness="1" CornerRadius="12" Padding="22" Margin="0,24,0,18">
      <Grid>
        <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <TextBlock Text="NAME" FontSize="10" FontWeight="Bold" Foreground="#B993D0"/>
        <TextBox x:Name="ActivationName" Grid.Row="1" Height="38" Margin="0,7,0,16" Padding="10,7" Background="#09080B" Foreground="White" BorderBrush="#3D2948"/>
        <TextBlock Grid.Row="2" Text="PLUS SERIAL KEY" FontSize="10" FontWeight="Bold" Foreground="#B993D0"/>
        <TextBox x:Name="ActivationSerial" Grid.Row="3" MinHeight="78" Margin="0,7,0,12" Padding="10" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" Background="#09080B" Foreground="White" BorderBrush="#3D2948"/>
        <CheckBox x:Name="RememberActivation" Grid.Row="4" Content="Remember this activation on this Windows account" IsChecked="True" Foreground="#C9ADD9"/>
      </Grid>
    </Border>
    <Grid Grid.Row="2">
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
      <TextBlock x:Name="ActivationStatus" Text="Enter the customer name and Plus key supplied by the owner." Foreground="#9B8CA4" TextWrapping="Wrap" Margin="0,0,0,12"/>
      <Button x:Name="ActivateButton" Grid.Row="1" Content="SIGN IN AND ACTIVATE" Height="44" Background="#9B63BE" Foreground="White" BorderThickness="0" FontWeight="Bold" Cursor="Hand"/>
    </Grid>
  </Grid>
</Window>
'@
    $activationReader = New-Object System.Xml.XmlNodeReader ([xml]$activationXaml)
    $activationWindow = [Windows.Markup.XamlReader]::Load($activationReader)
    $nameBox = $activationWindow.FindName('ActivationName')
    $serialBox = $activationWindow.FindName('ActivationSerial')
    $rememberBox = $activationWindow.FindName('RememberActivation')
    $statusText = $activationWindow.FindName('ActivationStatus')
    $activateButton = $activationWindow.FindName('ActivateButton')

    $savedName = ''
    $savedSerial = ''
    if ([WpfPlusLicenseManager]::TryLoad([ref]$savedName, [ref]$savedSerial)) {
        $nameBox.Text = $savedName
        $serialBox.Text = $savedSerial
        $statusText.Text = 'Saved Plus activation found. Select Sign in and activate.'
    }
    $activateButton.Add_Click({
        $message = ''
        if (-not [WpfPlusLicenseManager]::Verify($nameBox.Text, $serialBox.Text, [ref]$message)) {
            $statusText.Text = $message
            $statusText.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#EE5C78'))
            return
        }
        if ($rememberBox.IsChecked) { [WpfPlusLicenseManager]::Save($nameBox.Text, $serialBox.Text) }
        $activationWindow.DialogResult = $true
        $activationWindow.Close()
    })
    $activationWindow.Add_ContentRendered({ $nameBox.Focus() })
    return ($activationWindow.ShowDialog() -eq $true)
}

$warmupWindow.Close()
if (-not (Show-ActivationWindow)) { return }

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="R6 (:+" Width="1040" Height="700"
        MinWidth="760" MinHeight="520" WindowStartupLocation="CenterScreen"
        ResizeMode="CanResizeWithGrip"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        FontFamily="Segoe UI" Foreground="#D8B6F0">
  <Window.Resources>
    <SolidColorBrush x:Key="Surface" Color="#09080B"/>
    <SolidColorBrush x:Key="SurfaceRaised" Color="#111014"/>
    <SolidColorBrush x:Key="SurfaceSoft" Color="#18131D"/>
    <SolidColorBrush x:Key="Purple" Color="#9B63BE"/>
    <SolidColorBrush x:Key="PurpleBright" Color="#B982DB"/>
    <SolidColorBrush x:Key="PurpleMuted" Color="#B993D0"/>
    <SolidColorBrush x:Key="Line" Color="#3D2948"/>
    <SolidColorBrush x:Key="TextSoft" Color="#9B8CA4"/>

    <Style x:Key="NavButton" TargetType="Button">
      <Setter Property="Foreground" Value="#B993D0"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Padding" Value="18,0"/>
      <Setter Property="Height" Value="50"/>
      <Setter Property="Margin" Value="0,3"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
      <Setter Property="RenderTransform">
        <Setter.Value><ScaleTransform ScaleX="1" ScaleY="1"/></Setter.Value>
      </Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="NavBorder" Background="{TemplateBinding Background}" CornerRadius="10">
              <ContentPresenter VerticalAlignment="Center" HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="NavBorder" Property="Background" Value="#211728"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
              <Trigger Property="Tag" Value="Active">
                <Setter TargetName="NavBorder" Property="Background" Value="#32203D"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <EventTrigger RoutedEvent="MouseEnter">
          <BeginStoryboard>
            <Storyboard>
              <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.025" Duration="0:0:0.12"/>
              <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.025" Duration="0:0:0.12"/>
            </Storyboard>
          </BeginStoryboard>
        </EventTrigger>
        <EventTrigger RoutedEvent="MouseLeave">
          <BeginStoryboard>
            <Storyboard>
              <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.16"/>
              <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.16"/>
            </Storyboard>
          </BeginStoryboard>
        </EventTrigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="#9B63BE"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="20,11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
      <Setter Property="RenderTransform"><Setter.Value><ScaleTransform ScaleX="1" ScaleY="1"/></Setter.Value></Setter>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="ButtonBorder" Background="{TemplateBinding Background}" CornerRadius="9">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#B982DB"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="ButtonBorder" Property="Background" Value="#744493"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <EventTrigger RoutedEvent="MouseEnter"><BeginStoryboard><Storyboard>
          <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1.018" Duration="0:0:0.14"/>
          <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1.018" Duration="0:0:0.14"/>
        </Storyboard></BeginStoryboard></EventTrigger>
        <EventTrigger RoutedEvent="MouseLeave"><BeginStoryboard><Storyboard>
          <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleX)" To="1" Duration="0:0:0.18"/>
          <DoubleAnimation Storyboard.TargetProperty="(UIElement.RenderTransform).(ScaleTransform.ScaleY)" To="1" Duration="0:0:0.18"/>
        </Storyboard></BeginStoryboard></EventTrigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="SecondaryButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
      <Setter Property="Background" Value="#18131D"/>
      <Setter Property="Foreground" Value="#D8B6F0"/>
    </Style>

    <Style TargetType="Slider">
      <Setter Property="Foreground" Value="#9B63BE"/>
      <Setter Property="Margin" Value="0,8,0,0"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#121015"/>
      <Setter Property="Foreground" Value="#E8D9F2"/>
      <Setter Property="BorderBrush" Value="#3D2948"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,9"/>
      <Setter Property="CaretBrush" Value="#B982DB"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#C9ADD9"/>
      <Setter Property="Margin" Value="0,8"/>
      <Setter Property="FontSize" Value="14"/>
    </Style>
  </Window.Resources>

  <Border Background="#070608" BorderBrush="#A567C8" BorderThickness="1" CornerRadius="18">
    <Border.Effect><DropShadowEffect Color="#8F4EB5" BlurRadius="28" ShadowDepth="0" Opacity="0.28"/></Border.Effect>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="74"/><RowDefinition Height="*"/><RowDefinition Height="42"/></Grid.RowDefinitions>

      <Border x:Name="TitleBar" Grid.Row="0" Background="#0C0A0F" CornerRadius="18,18,0,0">
        <Grid Margin="24,0,18,0">
          <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
          <StackPanel VerticalAlignment="Center">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="R6 (:+" FontSize="25" FontWeight="Bold" Foreground="#B982DB"/>
              <Border Margin="12,3,0,0" Padding="9,3" Background="#2A1933" CornerRadius="8">
                <TextBlock Text="PLUS" FontSize="9" FontWeight="Bold" Foreground="#D9B8EC"/>
              </Border>
            </StackPanel>
            <TextBlock Text="Recoil Controller" FontSize="11" Foreground="#8F7D99" Margin="1,3,0,0"/>
          </StackPanel>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <Button x:Name="MinimizeButton" Content="_" Width="42" Height="34" Style="{StaticResource SecondaryButton}" Padding="0" Margin="0,0,8,0"/>
            <Button x:Name="CloseButton" Content="X" Width="42" Height="34" Style="{StaticResource SecondaryButton}" Padding="0"/>
          </StackPanel>
        </Grid>
      </Border>

      <Grid Grid.Row="1">
        <Grid.ColumnDefinitions><ColumnDefinition Width="220"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
        <Border Grid.Column="0" Background="#0B090D" BorderBrush="#24182A" BorderThickness="0,1,1,0">
          <Grid Margin="16,24,16,18">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
            <StackPanel>
              <TextBlock Text="WORKSPACE" Foreground="#6F6077" FontSize="10" FontWeight="Bold" Margin="14,0,0,10"/>
              <Button x:Name="ControlNav" Content="CONTROL" Style="{StaticResource NavButton}" Tag="Active"/>
              <Button x:Name="ProfilesNav" Content="PROFILES" Style="{StaticResource NavButton}"/>
              <Button x:Name="SettingsNav" Content="SETTINGS" Style="{StaticResource NavButton}"/>
            </StackPanel>
            <Border Grid.Row="2" Background="#141017" BorderBrush="#33213C" BorderThickness="1" CornerRadius="11" Padding="14">
              <StackPanel>
                <TextBlock Text="STATUS" Foreground="#7E6B87" FontSize="9" FontWeight="Bold"/>
                <StackPanel Orientation="Horizontal" Margin="0,9,0,0">
                  <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#6E6075" Margin="0,0,8,0"/>
                  <TextBlock x:Name="SidebarStatus" Text="Mode disabled" Foreground="#B8A2C4" FontSize="12"/>
                </StackPanel>
              </StackPanel>
            </Border>
          </Grid>
        </Border>

        <Grid Grid.Column="1" Background="#09080B">
          <Grid x:Name="ControlPage" Margin="32,26,32,24">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
              <StackPanel>
                <TextBlock Text="Motion control" Foreground="White" FontSize="27" FontWeight="SemiBold"/>
                <TextBlock Text="Adjust a configuration with precise decimal values." Foreground="#8F7D99" FontSize="13" Margin="0,6,0,0"/>
              </StackPanel>
              <Button x:Name="ModeButton" Grid.Column="1" Content="ENABLE MODE" Width="154" Height="42" Style="{StaticResource PrimaryButton}" Padding="0"/>
            </Grid>

            <Grid Grid.Row="1" Margin="0,26,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="1.4*"/><ColumnDefinition Width="18"/><ColumnDefinition Width="0.8*"/></Grid.ColumnDefinitions>
              <Border Grid.Column="0" Background="#111014" BorderBrush="#302039" BorderThickness="1" CornerRadius="14" Padding="24">
                <StackPanel>
                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="DOWNWARD SPEED" Foreground="#B993D0" FontSize="11" FontWeight="Bold"/><TextBlock Text="Vertical movement strength" Foreground="#716578" FontSize="11" Margin="0,4,0,0"/></StackPanel>
                    <TextBlock x:Name="DownReadout" Grid.Column="1" Text="5.0" Foreground="White" FontSize="24" FontWeight="SemiBold"/>
                  </Grid>
                  <Slider x:Name="DownSlider" Minimum="1" Maximum="10" Value="5" TickFrequency="0.01" IsSnapToTickEnabled="True" IsMoveToPointEnabled="True" SmallChange="0.01" LargeChange="1" Margin="0,18,0,0"/>
                  <Grid Margin="0,3,0,0"><TextBlock Text="1.0  Slow" Foreground="#75677D"/><TextBlock Text="10.0  Fast" Foreground="#75677D" HorizontalAlignment="Right"/></Grid>

                  <Border Height="1" Background="#2B1D32" Margin="0,25"/>

                  <Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <StackPanel><TextBlock Text="SIDE MOVEMENT" Foreground="#B993D0" FontSize="11" FontWeight="Bold"/><TextBlock Text="Negative moves left, positive moves right" Foreground="#716578" FontSize="11" Margin="0,4,0,0"/></StackPanel>
                    <TextBlock x:Name="SideReadout" Grid.Column="1" Text="0.0" Foreground="White" FontSize="24" FontWeight="SemiBold"/>
                  </Grid>
                   <Slider x:Name="SideSlider" Minimum="-10" Maximum="10" Value="0" TickFrequency="0.01" IsSnapToTickEnabled="True" IsMoveToPointEnabled="True" SmallChange="0.01" LargeChange="1" Margin="0,18,0,0"/>
                  <Grid Margin="0,3,0,0"><TextBlock Text="-10.0  Left" Foreground="#75677D"/><TextBlock Text="0.0" Foreground="#75677D" HorizontalAlignment="Center"/><TextBlock Text="Right  +10.0" Foreground="#75677D" HorizontalAlignment="Right"/></Grid>

                  <Border Height="1" Background="#2B1D32" Margin="0,25"/>
                  <StackPanel Orientation="Horizontal">
                    <Button x:Name="SaveCurrentButton" Content="SAVE CONFIGURATION" Width="190" Style="{StaticResource PrimaryButton}"/>
                    <Button x:Name="ResetButton" Content="RESET" Width="105" Margin="12,0,0,0" Style="{StaticResource SecondaryButton}"/>
                  </StackPanel>
                </StackPanel>
              </Border>

              <StackPanel Grid.Column="2">
                <Border Background="#16101B" BorderBrush="#4B3157" BorderThickness="1" CornerRadius="14" Padding="20">
                  <StackPanel>
                    <TextBlock Text="LIVE SUMMARY" Foreground="#B993D0" FontSize="10" FontWeight="Bold"/>
                    <TextBlock x:Name="DirectionSummary" Text="Straight downward" Foreground="White" FontSize="18" FontWeight="SemiBold" Margin="0,14,0,0" TextWrapping="Wrap"/>
                    <TextBlock x:Name="SpeedSummary" Text="750 pixels / second" Foreground="#94849D" Margin="0,7,0,0"/>
                  </StackPanel>
                </Border>
                <Border Background="#111014" BorderBrush="#302039" BorderThickness="1" CornerRadius="14" Padding="20" Margin="0,16,0,0">
                  <StackPanel>
                    <TextBlock Text="ACTIVATION" Foreground="#B993D0" FontSize="10" FontWeight="Bold"/>
                    <TextBlock Text="Hold Right first, then hold Left. Release Left to stop the current movement." TextWrapping="Wrap" Foreground="#A895B2" LineHeight="21" Margin="0,13,0,0"/>
                    <Border Background="#1A1320" CornerRadius="8" Padding="12" Margin="0,16,0,0"><TextBlock x:Name="ModeStateText" Text="MODE IS OFF" HorizontalAlignment="Center" Foreground="#B993D0" FontWeight="Bold"/></Border>
                  </StackPanel>
                </Border>
              </StackPanel>
            </Grid>
          </Grid>

          <Grid x:Name="ProfilesPage" Visibility="Collapsed" Margin="32,26,32,24">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <StackPanel><TextBlock Text="Configuration library" Foreground="White" FontSize="27" FontWeight="SemiBold"/><TextBlock Text="Expandable categories arranged like your sketch. Add as many custom boxes as you need." Foreground="#8F7D99" FontSize="13" Margin="0,6,0,0"/></StackPanel>
            <Grid Grid.Row="1" Margin="0,26,0,0">
              <Grid.ColumnDefinitions><ColumnDefinition Width="0.9*"/><ColumnDefinition Width="18"/><ColumnDefinition Width="1.1*"/></Grid.ColumnDefinitions>
              <Border Background="#0E0C11" BorderBrush="#3A2644" BorderThickness="1" CornerRadius="14" Padding="16">
                <Grid>
                  <Grid.RowDefinitions><RowDefinition Height="34"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                  <Grid>
                    <TextBlock Text="CUSTOM CATEGORIES" Foreground="#B993D0" FontSize="10" FontWeight="Bold" VerticalAlignment="Center"/>
                    <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
                      <Button x:Name="CategoryAddButton" Content="+" Width="25" Height="23" Padding="0" FontSize="10" Style="{StaticResource PrimaryButton}" ToolTip="Add category"/>
                      <Button x:Name="CategoryRemoveButton" Content="-" Width="25" Height="23" Padding="0" FontSize="10" Margin="6,0,0,0" Style="{StaticResource SecondaryButton}" ToolTip="Remove selected category"/>
                    </StackPanel>
                  </Grid>
                  <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Margin="0,10,0,0">
                    <StackPanel x:Name="CategoryStack"/>
                  </ScrollViewer>
                </Grid>
              </Border>
              <Border Grid.Column="2" Background="#111014" BorderBrush="#302039" BorderThickness="1" CornerRadius="14" Padding="24">
                <StackPanel>
                  <TextBlock Text="SELECTED PRESET" Foreground="#B993D0" FontSize="10" FontWeight="Bold"/>
                  <TextBlock x:Name="SelectedPresetHeading" Text="Select a smaller box" Foreground="White" FontSize="22" FontWeight="SemiBold" Margin="0,12,0,8" TextWrapping="Wrap"/>
                  <TextBlock x:Name="SelectedCategoryText" Text="Expand a category on the left, then choose one of its child presets." Foreground="#8F7D99" TextWrapping="Wrap" LineHeight="20" Margin="0,0,0,22"/>
                  <TextBlock Text="Preset name" Foreground="#8F7D99" Margin="0,0,0,7"/><TextBox x:Name="SelectedPresetName" Text=""/>
                  <Grid Margin="0,18,0,0"><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="14"/><ColumnDefinition/></Grid.ColumnDefinitions><StackPanel><TextBlock Text="Down value" Foreground="#8F7D99"/><TextBox x:Name="SelectedDownValue" Text="5.0" Margin="0,7,0,0"/></StackPanel><StackPanel Grid.Column="2"><TextBlock Text="Side value" Foreground="#8F7D99"/><TextBox x:Name="SelectedSideValue" Text="0.0" Margin="0,7,0,0"/></StackPanel></Grid>
                  <StackPanel Orientation="Horizontal" Margin="0,24,0,0"><Button x:Name="ApplyPresetButton" Content="SAVE VALUES" Width="140" Style="{StaticResource PrimaryButton}"/><Button x:Name="LoadPresetButton" Content="LOAD" Width="100" Margin="12,0,0,0" Style="{StaticResource SecondaryButton}"/></StackPanel>
                  <Border Background="#17121B" CornerRadius="9" Padding="13" Margin="0,22,0,0"><TextBlock Text="Names and decimal values are saved only to the currently activated account." Foreground="#8F7D99" TextWrapping="Wrap" LineHeight="19"/></Border>
                </StackPanel>
              </Border>
            </Grid>
          </Grid>

          <Grid x:Name="SettingsPage" Visibility="Collapsed" Margin="32,26,32,24">
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <StackPanel><TextBlock Text="Application settings" Foreground="White" FontSize="27" FontWeight="SemiBold"/><TextBlock Text="Window, safety, and appearance preferences." Foreground="#8F7D99" FontSize="13" Margin="0,6,0,0"/></StackPanel>
            <StackPanel Grid.Row="1" Margin="0,26,0,0" MaxWidth="620" HorizontalAlignment="Stretch">
              <Border Background="#111014" BorderBrush="#302039" BorderThickness="1" CornerRadius="14" Padding="22">
                <StackPanel><TextBlock Text="WINDOW" Foreground="#B993D0" FontSize="10" FontWeight="Bold"/><CheckBox x:Name="AlwaysOnTopCheck" Content="Keep the application above other windows" Margin="0,17,0,8"/><CheckBox x:Name="RememberSizeCheck" Content="Remember window size and position" IsChecked="True"/><CheckBox Content="Minimize normally to the Windows taskbar" IsChecked="True" IsEnabled="False"/></StackPanel>
              </Border>
              <Border Background="#111014" BorderBrush="#302039" BorderThickness="1" CornerRadius="14" Padding="22" Margin="0,16,0,0">
                <StackPanel><TextBlock Text="SAFETY" Foreground="#B993D0" FontSize="10" FontWeight="Bold"/><CheckBox x:Name="ReleaseOnCloseCheck" Content="Release input automatically if the window closes" IsChecked="True" Margin="0,17,0,8"/><CheckBox x:Name="StopAtEdgesCheck" Content="Stop movement at screen edges" IsChecked="True"/><CheckBox x:Name="ActiveIndicatorCheck" Content="Show a clear active-state indicator" IsChecked="True"/></StackPanel>
              </Border>
            </StackPanel>
          </Grid>
        </Grid>
      </Grid>

      <Border Grid.Row="2" Background="#0C0A0F" CornerRadius="0,0,18,18" BorderBrush="#24182A" BorderThickness="0,1,0,0">
        <Grid Margin="24,0"><TextBlock x:Name="FooterStatus" Text="Ready" VerticalAlignment="Center" Foreground="#75677D" FontSize="11"/><TextBlock Text="R6 (:+" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#6A5674" FontSize="10" FontWeight="Bold"/></Grid>
      </Border>
      <ResizeGrip Grid.RowSpan="3" HorizontalAlignment="Right" VerticalAlignment="Bottom" Width="18" Height="18" Margin="0,0,4,4" Foreground="#9B63BE"/>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

function Find-Control([string]$name) { $window.FindName($name) }

$titleBar = Find-Control 'TitleBar'
$closeButton = Find-Control 'CloseButton'
$minimizeButton = Find-Control 'MinimizeButton'
$controlNav = Find-Control 'ControlNav'
$profilesNav = Find-Control 'ProfilesNav'
$settingsNav = Find-Control 'SettingsNav'
$controlPage = Find-Control 'ControlPage'
$profilesPage = Find-Control 'ProfilesPage'
$settingsPage = Find-Control 'SettingsPage'
$modeButton = Find-Control 'ModeButton'
$modeStateText = Find-Control 'ModeStateText'
$sidebarStatus = Find-Control 'SidebarStatus'
$statusDot = Find-Control 'StatusDot'
$downSlider = Find-Control 'DownSlider'
$sideSlider = Find-Control 'SideSlider'
$downReadout = Find-Control 'DownReadout'
$sideReadout = Find-Control 'SideReadout'
$directionSummary = Find-Control 'DirectionSummary'
$speedSummary = Find-Control 'SpeedSummary'
$resetButton = Find-Control 'ResetButton'
$saveCurrentButton = Find-Control 'SaveCurrentButton'
$footerStatus = Find-Control 'FooterStatus'
$categoryStack = Find-Control 'CategoryStack'
$categoryAddButton = Find-Control 'CategoryAddButton'
$categoryRemoveButton = Find-Control 'CategoryRemoveButton'
$selectedPresetHeading = Find-Control 'SelectedPresetHeading'
$selectedCategoryText = Find-Control 'SelectedCategoryText'
$selectedPresetName = Find-Control 'SelectedPresetName'
$selectedDownValue = Find-Control 'SelectedDownValue'
$selectedSideValue = Find-Control 'SelectedSideValue'
$applyPresetButton = Find-Control 'ApplyPresetButton'
$loadPresetButton = Find-Control 'LoadPresetButton'
$alwaysOnTopCheck = Find-Control 'AlwaysOnTopCheck'
$rememberSizeCheck = Find-Control 'RememberSizeCheck'
$releaseOnCloseCheck = Find-Control 'ReleaseOnCloseCheck'
$stopAtEdgesCheck = Find-Control 'StopAtEdgesCheck'
$activeIndicatorCheck = Find-Control 'ActiveIndicatorCheck'
$global:R6PlusProfileUi = [pscustomobject]@{
    DownSlider = $downSlider
    SideSlider = $sideSlider
    FooterStatus = $footerStatus
    SelectedPresetHeading = $selectedPresetHeading
    SelectedCategoryText = $selectedCategoryText
    SelectedPresetName = $selectedPresetName
    SelectedDownValue = $selectedDownValue
    SelectedSideValue = $selectedSideValue
}

$titleBar.Add_MouseLeftButtonDown({ if ($_.ButtonState -eq 'Pressed') { $window.DragMove() } })
$closeButton.Add_Click({ $window.Close() })
$minimizeButton.Add_Click({ $window.WindowState = 'Minimized' })

function Show-Page([string]$page) {
    $controlPage.Visibility = if ($page -eq 'Control') { 'Visible' } else { 'Collapsed' }
    $profilesPage.Visibility = if ($page -eq 'Profiles') { 'Visible' } else { 'Collapsed' }
    $settingsPage.Visibility = if ($page -eq 'Settings') { 'Visible' } else { 'Collapsed' }
    $controlNav.Tag = if ($page -eq 'Control') { 'Active' } else { $null }
    $profilesNav.Tag = if ($page -eq 'Profiles') { 'Active' } else { $null }
    $settingsNav.Tag = if ($page -eq 'Settings') { 'Active' } else { $null }
    $visiblePage = if ($page -eq 'Control') { $controlPage } elseif ($page -eq 'Profiles') { $profilesPage } else { $settingsPage }
    $visiblePage.Opacity = 0
    $fade = New-Object Windows.Media.Animation.DoubleAnimation
    $fade.From = 0
    $fade.To = 1
    $fade.Duration = [Windows.Duration]::new([TimeSpan]::FromMilliseconds(190))
    $visiblePage.BeginAnimation([Windows.UIElement]::OpacityProperty, $fade)
}

$controlNav.Add_Click({ & $global:fnShowPage 'Control' })
$profilesNav.Add_Click({ & $global:fnShowPage 'Profiles' })
$settingsNav.Add_Click({ & $global:fnShowPage 'Settings' })

function Update-Summary {
    $down = [double]$downSlider.Value
    $side = [double]$sideSlider.Value
    [R6MotionEngine]::DownSpeed = $down
    [R6MotionEngine]::SideSpeed = $side
    $downReadout.Text = $down.ToString('0.##')
    $sideReadout.Text = if ($side -gt 0) { '+' + $side.ToString('0.##') } else { $side.ToString('0.##') }
    $directionSummary.Text = if ([math]::Abs($side) -lt 0.05) { 'Straight downward' } elseif ($side -lt 0) { 'Downward left' } else { 'Downward right' }
    $speedSummary.Text = (($down * 150).ToString('0.##')) + ' px/s down  |  ' + (($side * 150).ToString('0.##')) + ' px/s X'
}

$downSlider.Add_ValueChanged({
    & $global:fnUpdateSummary
})
$sideSlider.Add_ValueChanged({
    & $global:fnUpdateSummary
})
$resetButton.Add_Click({ $downSlider.Value = 5; $sideSlider.Value = 0; $footerStatus.Text = 'Configuration reset to defaults' })

$localDataRoot = [Environment]::GetFolderPath('LocalApplicationData')
$windowsUserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$safeLicenseId = ([WpfPlusLicenseManager]::ActiveLicenseId -replace '[^A-Za-z0-9_-]', '_')
$legacyAccountRoot = Join-Path $localDataRoot ('R6-Plus\Accounts\' + $safeLicenseId)
$script:accountRoot = Join-Path $localDataRoot ('R6-Plus\Users\' + $windowsUserSid + '\Accounts\' + $safeLicenseId)
$script:profilesPath = Join-Path $script:accountRoot 'wpf-profiles.json'
$script:settingsPath = Join-Path $script:accountRoot 'wpf-settings.json'
[IO.Directory]::CreateDirectory($script:accountRoot) | Out-Null
if (-not (Test-Path -LiteralPath $script:profilesPath)) {
    $legacyProfiles = Join-Path $legacyAccountRoot 'wpf-profiles.json'
    if (Test-Path -LiteralPath $legacyProfiles) { [IO.File]::Copy($legacyProfiles, $script:profilesPath, $false) }
}
if (-not (Test-Path -LiteralPath $script:settingsPath)) {
    $legacySettings = Join-Path $legacyAccountRoot 'wpf-settings.json'
    if (Test-Path -LiteralPath $legacySettings) { [IO.File]::Copy($legacySettings, $script:settingsPath, $false) }
}
$global:R6PlusProfileState = [pscustomobject]@{
    Categories = New-Object Collections.ArrayList
    SelectedCategory = $null
    SelectedPreset = $null
    SelectedPresetNameBox = $null
    PendingSaveCurrent = $false
    PendingDown = 5.0
    PendingSide = 0.0
}

function New-PresetModel([string]$name, [double]$down = 5, [double]$side = 0) {
    [pscustomobject]@{ Name = $name; Down = $down; Side = $side }
}

function New-CategoryModel([string]$name) {
    $presets = New-Object Collections.ArrayList
    [void]$presets.Add((New-PresetModel 'Preset 01'))
    [void]$presets.Add((New-PresetModel 'Preset 02'))
    [pscustomobject]@{ Name = $name; Presets = $presets }
}

function Save-ProfileModel {
    try {
        [IO.Directory]::CreateDirectory($script:accountRoot) | Out-Null
        $document = [pscustomobject]@{ Version = 1; Categories = @($global:R6PlusProfileState.Categories) }
        $json = $document | ConvertTo-Json -Depth 7
        $temporaryPath = $script:profilesPath + '.tmp'
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $script:profilesPath -Force | Out-Null
        return $true
    } catch {
        $footerStatus.Text = 'Could not save profiles: ' + $_.Exception.Message
        return $false
    }
}

function Load-ProfileModel {
    $global:R6PlusProfileState.Categories.Clear()
    try {
        if (Test-Path -LiteralPath $script:profilesPath) {
            $document = Get-Content -LiteralPath $script:profilesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($storedCategory in @($document.Categories)) {
                $presets = New-Object Collections.ArrayList
                foreach ($storedPreset in @($storedCategory.Presets)) {
                    [void]$presets.Add((New-PresetModel ([string]$storedPreset.Name) ([double]$storedPreset.Down) ([double]$storedPreset.Side)))
                }
                if ($presets.Count -eq 0) { [void]$presets.Add((New-PresetModel 'Preset 01')) }
                [void]$global:R6PlusProfileState.Categories.Add([pscustomobject]@{ Name = [string]$storedCategory.Name; Presets = $presets })
            }
        }
    } catch { $global:R6PlusProfileState.Categories.Clear() }
    if ($global:R6PlusProfileState.Categories.Count -eq 0) {
        1..8 | ForEach-Object { [void]$global:R6PlusProfileState.Categories.Add((New-CategoryModel ('Category ' + $_.ToString('00')))) }
        Save-ProfileModel
    }
}

function Select-Preset($category, $preset, $nameBox) {
    $ui = $global:R6PlusProfileUi
    $global:R6PlusProfileState.SelectedCategory = $category
    $global:R6PlusProfileState.SelectedPreset = $preset
    $global:R6PlusProfileState.SelectedPresetNameBox = $nameBox
    $ui.SelectedPresetHeading.Text = $preset.Name
    $ui.SelectedCategoryText.Text = 'Inside ' + $category.Name
    $ui.SelectedPresetName.Text = $preset.Name
$ui.SelectedDownValue.Text = ([double]$preset.Down).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
$ui.SelectedSideValue.Text = ([double]$preset.Side).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
    $ui.FooterStatus.Text = 'Selected ' + $category.Name + ' / ' + $preset.Name
}

function Clear-SelectedPresetView {
    $ui = $global:R6PlusProfileUi
    $global:R6PlusProfileState.SelectedCategory = $null
    $global:R6PlusProfileState.SelectedPreset = $null
    $global:R6PlusProfileState.SelectedPresetNameBox = $null
    $ui.SelectedPresetHeading.Text = 'Select a child preset'
    $ui.SelectedCategoryText.Text = 'Expand a category on the left, then choose one of its child presets.'
    $ui.SelectedPresetName.Text = ''
    $ui.SelectedDownValue.Text = '5.0'
    $ui.SelectedSideValue.Text = '0.0'
}

function Add-PresetView([Windows.Controls.StackPanel]$panel, $category, $preset) {
    $row = New-Object Windows.Controls.Border
    $row.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#17121B'))
    $row.BorderBrush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#34223E'))
    $row.BorderThickness = 1; $row.CornerRadius = 8; $row.Padding = '9,7'; $row.Margin = '0,4,0,4'
    $grid = New-Object Windows.Controls.Grid
    $first = New-Object Windows.Controls.ColumnDefinition
    $second = New-Object Windows.Controls.ColumnDefinition; $second.Width = '58'
    $third = New-Object Windows.Controls.ColumnDefinition; $third.Width = '28'
    [void]$grid.ColumnDefinitions.Add($first); [void]$grid.ColumnDefinitions.Add($second); [void]$grid.ColumnDefinitions.Add($third)
    $nameBox = New-Object Windows.Controls.TextBox
    $nameBox.Text = $preset.Name; $nameBox.Background = [Windows.Media.Brushes]::Transparent; $nameBox.BorderThickness = 0; $nameBox.Padding = '5,4'; $nameBox.Margin = '0,0,24,0'
    $nameBox.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#D8B6F0'))
    $openButton = New-Object Windows.Controls.Button
    $openButton.Content = 'OPEN'; $openButton.Style = $window.Resources['SecondaryButton']; $openButton.Padding = '0'; $openButton.Height = 27; $openButton.FontSize = 9
    [Windows.Controls.Grid]::SetColumn($openButton, 1)
    $deleteButton = New-Object Windows.Controls.Button
    $deleteButton.Content = 'X'; $deleteButton.Background = [Windows.Media.Brushes]::Transparent; $deleteButton.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#B993D0')); $deleteButton.BorderThickness = 0; $deleteButton.Padding = '0'; $deleteButton.Width = 18; $deleteButton.Height = 18; $deleteButton.FontSize = 11; $deleteButton.FontWeight = 'Bold'; $deleteButton.Cursor = 'Hand'; $deleteButton.ToolTip = 'Delete preset'; $deleteButton.HorizontalContentAlignment = 'Center'; $deleteButton.VerticalContentAlignment = 'Center'; $deleteButton.HorizontalAlignment = 'Right'; $deleteButton.VerticalAlignment = 'Top'; $deleteButton.Margin = '0,-5,-5,0'
    [Windows.Controls.Grid]::SetColumnSpan($deleteButton, 3)
    [void]$grid.Children.Add($nameBox); [void]$grid.Children.Add($openButton); [void]$grid.Children.Add($deleteButton); $row.Child = $grid
    [void]$panel.Children.Insert([math]::Max(0, $panel.Children.Count - 1), $row)
    $nameBox.Add_LostFocus({
        $cleanName = $nameBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($cleanName)) { $cleanName = 'Unnamed preset'; $nameBox.Text = $cleanName }
        $preset.Name = $cleanName; [void](& $global:fnSaveProfile)
        if ($global:R6PlusProfileState.SelectedPreset -eq $preset) { $selectedPresetHeading.Text = $cleanName; $selectedPresetName.Text = $cleanName }
    }.GetNewClosure())
    $openButton.Add_Click({
        # Keep this handler self-contained so WPF cannot lose the selection
        # when the callback is raised outside the main script scope.
        $global:R6PlusProfileState.SelectedCategory = $category
        $global:R6PlusProfileState.SelectedPreset = $preset
        $global:R6PlusProfileState.SelectedPresetNameBox = $nameBox
        $ui = $global:R6PlusProfileUi
        $ui.SelectedPresetHeading.Text = $preset.Name
        $ui.SelectedCategoryText.Text = 'Inside ' + $category.Name
        $ui.SelectedPresetName.Text = $preset.Name
        if ($global:R6PlusProfileState.PendingSaveCurrent) {
$ui.SelectedDownValue.Text = ([double]$global:R6PlusProfileState.PendingDown).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
$ui.SelectedSideValue.Text = ([double]$global:R6PlusProfileState.PendingSide).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
            $global:R6PlusProfileState.PendingSaveCurrent = $false
            $ui.FooterStatus.Text = 'Current values ready for ' + $category.Name + ' / ' + $preset.Name + ' - click SAVE VALUES'
        } else {
$ui.SelectedDownValue.Text = ([double]$preset.Down).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
$ui.SelectedSideValue.Text = ([double]$preset.Side).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
            $ui.FooterStatus.Text = 'Opened ' + $category.Name + ' / ' + $preset.Name
        }
    }.GetNewClosure())
    $deleteButton.Add_Click({
        [void]$category.Presets.Remove($preset)
        [void]$panel.Children.Remove($row)
        if ($global:R6PlusProfileState.SelectedPreset -eq $preset) {
            & $global:fnClearSelectedPreset
        }
        [void](& $global:fnSaveProfile)
        $footerStatus.Text = 'Deleted preset from ' + $category.Name
    }.GetNewClosure())
}

function Add-CategoryView($category, [bool]$expanded = $false) {
    $expander = New-Object Windows.Controls.Expander
    $expander.IsExpanded = $expanded; $expander.Margin = '0,0,0,8'; $expander.Tag = $category
    $expander.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#D8B6F0'))
    $headerBorder = New-Object Windows.Controls.Border
    $headerBorder.Background = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#201725'))
    $headerBorder.BorderBrush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#513160'))
    $headerBorder.BorderThickness = 1; $headerBorder.CornerRadius = 9; $headerBorder.Padding = '8,5'
    $categoryNameBox = New-Object Windows.Controls.TextBox
    $categoryNameBox.Text = $category.Name; $categoryNameBox.Background = [Windows.Media.Brushes]::Transparent; $categoryNameBox.BorderThickness = 0; $categoryNameBox.FontWeight = 'SemiBold'
    $categoryNameBox.Foreground = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#F0E2F8'))
    $headerBorder.Child = $categoryNameBox; $expander.Header = $headerBorder
    $children = New-Object Windows.Controls.StackPanel; $children.Margin = '25,6,3,4'
    $addChildButton = New-Object Windows.Controls.Button
    $addChildButton.Content = '+  Add child preset'; $addChildButton.Style = $window.Resources['SecondaryButton']; $addChildButton.Height = 31; $addChildButton.Padding = '0'; $addChildButton.Margin = '0,4,0,1'
    [void]$children.Children.Add($addChildButton); $expander.Content = $children
    foreach ($preset in @($category.Presets)) { Add-PresetView $children $category $preset }
    $categoryNameBox.Add_LostFocus({
        $cleanName = $categoryNameBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($cleanName)) { $cleanName = 'Unnamed category'; $categoryNameBox.Text = $cleanName }
        $category.Name = $cleanName; [void](& $global:fnSaveProfile)
        if ($global:R6PlusProfileState.SelectedCategory -eq $category) { $selectedCategoryText.Text = 'Inside ' + $cleanName }
    }.GetNewClosure())
    $expander.Add_Expanded({ $global:R6PlusProfileState.SelectedCategory = $category }.GetNewClosure())
    $addChildButton.Add_Click({
        $newPreset = & $global:fnNewPresetModel ('Preset ' + ($category.Presets.Count + 1).ToString('00'))
        [void]$category.Presets.Add($newPreset); & $global:fnAddPresetView $children $category $newPreset; [void](& $global:fnSaveProfile)
        $footerStatus.Text = 'Added a preset to ' + $category.Name
    }.GetNewClosure())
    [void]$categoryStack.Children.Add($expander)
}

function Render-Categories {
    $categoryStack.Children.Clear()
    $index = 0
    foreach ($category in @($global:R6PlusProfileState.Categories)) { Add-CategoryView $category ($index -eq 0); $index++ }
}

Load-ProfileModel
Render-Categories

$categoryAddButton.Add_Click({
    $category = & $global:fnNewCategoryModel ('Category ' + ($global:R6PlusProfileState.Categories.Count + 1).ToString('00'))
    [void]$global:R6PlusProfileState.Categories.Add($category); & $global:fnAddCategoryView $category $true; $global:R6PlusProfileState.SelectedCategory = $category; [void](& $global:fnSaveProfile)
    $footerStatus.Text = 'Added a new category'
})
$categoryRemoveButton.Add_Click({
    if ($global:R6PlusProfileState.Categories.Count -eq 0) { return }
    $target = if ($null -ne $global:R6PlusProfileState.SelectedCategory) { $global:R6PlusProfileState.SelectedCategory } else { $global:R6PlusProfileState.Categories[$global:R6PlusProfileState.Categories.Count - 1] }
    [void]$global:R6PlusProfileState.Categories.Remove($target); & $global:fnClearSelectedPreset; & $global:fnRenderCategories; [void](& $global:fnSaveProfile)
    $footerStatus.Text = 'Removed the selected category'
})

function Convert-ProfileNumber([string]$text) {
    $cleanText = if ($null -eq $text) { '' } else { $text.Trim() }
    if ([string]::IsNullOrWhiteSpace($cleanText)) { return $null }

    # Keep the value the user entered; reject anything with more than two
    # digits after the decimal instead of rounding it during save.
    if ($cleanText -notmatch '^[+-]?\d+(?:[\.,]\d{0,2})?$') { return $null }
    $normalizedText = $cleanText.Replace(',', '.')
    $value = 0.0
    if ([double]::TryParse($normalizedText, [Globalization.NumberStyles]::AllowLeadingSign -bor [Globalization.NumberStyles]::AllowDecimalPoint, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) { return $value }
    return $null
}

function Save-SelectedPreset {
    $ui = $global:R6PlusProfileUi
    if ($null -eq $global:R6PlusProfileState.SelectedPreset) { $ui.FooterStatus.Text = 'Select a child preset first'; return $false }
    $downText = if ($null -eq $ui.SelectedDownValue.Text) { '' } else { $ui.SelectedDownValue.Text.Trim() }
    $sideText = if ($null -eq $ui.SelectedSideValue.Text) { '' } else { $ui.SelectedSideValue.Text.Trim() }
    $down = & $global:fnConvertProfileNumber $downText
    $side = & $global:fnConvertProfileNumber $sideText
    if ($null -eq $down -or $null -eq $side) {
        $ui.FooterStatus.Text = 'Use valid values with no more than two decimal places'; return $false
    }
    if ($down -lt 1 -or $down -gt 10 -or $side -lt -10 -or $side -gt 10) {
        $ui.FooterStatus.Text = 'Down must be 1 to 10 and Side must be -10 to 10'; return $false
    }
    $global:R6PlusProfileState.SelectedPreset.Name = if ([string]::IsNullOrWhiteSpace($ui.SelectedPresetName.Text)) { 'Unnamed preset' } else { $ui.SelectedPresetName.Text.Trim() }
    # Store the parsed value exactly as entered. Do not round, clamp, or
    # rewrite the text fields during Save Values.
    $global:R6PlusProfileState.SelectedPreset.Down = [double]$down
    $global:R6PlusProfileState.SelectedPreset.Side = [double]$side
    $global:R6PlusProfileState.SelectedPresetNameBox.Text = $global:R6PlusProfileState.SelectedPreset.Name
    $ui.SelectedPresetHeading.Text = $global:R6PlusProfileState.SelectedPreset.Name
    [void](& $global:fnSaveProfile); $ui.FooterStatus.Text = 'Saved values to this account'; return $true
}

$applyPresetButton.Add_Click({ [void](& $global:fnSaveSelectedPreset) })
$saveCurrentButton.Add_Click({
    $global:R6PlusProfileState.PendingSaveCurrent = $true
    $global:R6PlusProfileState.PendingDown = [double]$global:R6PlusProfileUi.DownSlider.Value
    $global:R6PlusProfileState.PendingSide = [double]$global:R6PlusProfileUi.SideSlider.Value
    $global:R6PlusProfileState.SelectedCategory = $null
    $global:R6PlusProfileState.SelectedPreset = $null
    $global:R6PlusProfileState.SelectedPresetNameBox = $null
    & $global:fnClearSelectedPreset
    & $global:fnShowPage 'Profiles'
    $footerStatus.Text = 'Click OPEN on the child preset that should receive the current values'
})
$loadPresetButton.Add_Click({
    if ($null -eq $global:R6PlusProfileState.SelectedPreset) { $footerStatus.Text = 'Select a child preset first'; return }
    $downSlider.Value = [math]::Max($downSlider.Minimum, [math]::Min($downSlider.Maximum, [double]$global:R6PlusProfileState.SelectedPreset.Down))
    $sideSlider.Value = [math]::Max($sideSlider.Minimum, [math]::Min($sideSlider.Maximum, [double]$global:R6PlusProfileState.SelectedPreset.Side))
    & $global:fnUpdateSummary
    & $global:fnShowPage 'Control'; $footerStatus.Text = 'Loaded the selected values into Control'
})

function Save-AppSettings {
    $settings = [pscustomobject]@{
        AlwaysOnTop = [bool]$alwaysOnTopCheck.IsChecked
        RememberSize = [bool]$rememberSizeCheck.IsChecked
        ReleaseOnClose = [bool]$releaseOnCloseCheck.IsChecked
        StopAtEdges = [bool]$stopAtEdgesCheck.IsChecked
        ActiveIndicator = [bool]$activeIndicatorCheck.IsChecked
        Width = [math]::Round($window.RestoreBounds.Width)
        Height = [math]::Round($window.RestoreBounds.Height)
        Left = [math]::Round($window.RestoreBounds.Left)
        Top = [math]::Round($window.RestoreBounds.Top)
    }
    [IO.File]::WriteAllText($script:settingsPath, ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}

function Load-AppSettings {
    if (-not (Test-Path -LiteralPath $script:settingsPath)) { return }
    try {
        $settings = Get-Content -LiteralPath $script:settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $alwaysOnTopCheck.IsChecked = [bool]$settings.AlwaysOnTop
        $rememberSizeCheck.IsChecked = [bool]$settings.RememberSize
        $releaseOnCloseCheck.IsChecked = [bool]$settings.ReleaseOnClose
        $stopAtEdgesCheck.IsChecked = [bool]$settings.StopAtEdges
        $activeIndicatorCheck.IsChecked = [bool]$settings.ActiveIndicator
        $window.Topmost = [bool]$settings.AlwaysOnTop
        if ([bool]$settings.RememberSize) {
            if ([double]$settings.Width -ge $window.MinWidth) { $window.Width = [double]$settings.Width }
            if ([double]$settings.Height -ge $window.MinHeight) { $window.Height = [double]$settings.Height }
            $workArea = [Windows.SystemParameters]::WorkArea
            if ([double]$settings.Left -ge $workArea.Left -and [double]$settings.Left -lt $workArea.Right - 80) { $window.Left = [double]$settings.Left }
            if ([double]$settings.Top -ge $workArea.Top -and [double]$settings.Top -lt $workArea.Bottom - 80) { $window.Top = [double]$settings.Top }
        }
    } catch { $footerStatus.Text = 'Settings were reset because the saved file could not be read' }
}

# WPF event callbacks use their own scope; keep explicit references to the
# profile and settings functions so callbacks can always reach them.
$global:fnShowPage = ${function:Show-Page}.GetNewClosure()
$global:fnUpdateSummary = ${function:Update-Summary}.GetNewClosure()
$global:fnSaveProfile = ${function:Save-ProfileModel}.GetNewClosure()
$global:fnSelectPreset = ${function:Select-Preset}.GetNewClosure()
$global:fnClearSelectedPreset = ${function:Clear-SelectedPresetView}.GetNewClosure()
$global:fnNewPresetModel = ${function:New-PresetModel}.GetNewClosure()
$global:fnNewCategoryModel = ${function:New-CategoryModel}.GetNewClosure()
$global:fnAddPresetView = ${function:Add-PresetView}.GetNewClosure()
$global:fnAddCategoryView = ${function:Add-CategoryView}.GetNewClosure()
$global:fnRenderCategories = ${function:Render-Categories}.GetNewClosure()
$global:fnConvertProfileNumber = ${function:Convert-ProfileNumber}.GetNewClosure()
$global:fnSaveSelectedPreset = ${function:Save-SelectedPreset}.GetNewClosure()
$global:fnSaveAppSettings = ${function:Save-AppSettings}.GetNewClosure()

Load-AppSettings
$alwaysOnTopCheck.Add_Checked({ $window.Topmost = $true; & $global:fnSaveAppSettings })
$alwaysOnTopCheck.Add_Unchecked({ $window.Topmost = $false; & $global:fnSaveAppSettings })
foreach ($settingControl in @($rememberSizeCheck, $releaseOnCloseCheck, $stopAtEdgesCheck, $activeIndicatorCheck)) {
    $settingControl.Add_Checked({ & $global:fnSaveAppSettings })
    $settingControl.Add_Unchecked({ & $global:fnSaveAppSettings })
}
$window.Add_Closing({ & $global:fnSaveAppSettings })

$script:modeEnabled = $false
$modeButton.Add_Click({
    $script:modeEnabled = -not $script:modeEnabled
    if ($script:modeEnabled) {
        $modeButton.Content = 'DISABLE MODE'
        $modeStateText.Text = 'MODE IS ARMED'
        $sidebarStatus.Text = 'Mode armed'
        $statusDot.Fill = [Windows.Media.Brushes]::MediumPurple
        [R6MotionEngine]::Start()
    } else {
        $modeButton.Content = 'ENABLE MODE'
        $modeStateText.Text = 'MODE IS OFF'
        $sidebarStatus.Text = 'Mode disabled'
        $statusDot.Fill = New-Object Windows.Media.SolidColorBrush ([Windows.Media.ColorConverter]::ConvertFromString('#6E6075'))
        [R6MotionEngine]::Stop()
    }
})

$window.Add_Closing({ [R6MotionEngine]::Stop(); & $global:fnSaveAppSettings })

Update-Summary
$licenseWatchdog = New-Object Windows.Threading.DispatcherTimer
$licenseWatchdog.Interval = [TimeSpan]::FromSeconds(5)
$licenseWatchdog.Add_Tick({
    $licenseMessage = ''
    if (-not [WpfPlusLicenseManager]::CheckCurrentLicense([ref]$licenseMessage)) {
        $licenseWatchdog.Stop()
        [R6MotionEngine]::Stop()
        $window.Close()
        [System.Windows.MessageBox]::Show(
            'This license has been terminated by the owner. The application will now close.',
            'Access terminated',
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Stop) | Out-Null
    }
}.GetNewClosure())
$window.Add_Closed({ $licenseWatchdog.Stop() }.GetNewClosure())
$licenseWatchdog.Start()
[void]$window.ShowDialog()
