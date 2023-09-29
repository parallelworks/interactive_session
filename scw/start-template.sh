set -x

kernel_version=$(uname -r | tr '[:upper:]' '[:lower:]')


configure_X_server() {
    if nvidia-smi &>/dev/null; then
        # GPU Support
        # Configure the X server to start automatically when the Linux server boots.
        if [[ $(sudo systemctl get-default) == "multi-user.target" ]]; then
            sudo systemctl set-default graphical.target  
        fi
        # Start the X server.
        sudo systemctl isolate graphical.target
        # Verify that the X server is running.
        ps aux | grep X | grep -v grep
        # Generate an updated xorg.conf
        sudo rm -rf /etc/X11/XF86Config*
        #sudo nvidia-xconfig --preserve-busid --enable-all-gpus
        # If you're using a G3 or G4 Amazon EC2 instance and you want to use a multi-monitor console session
        sudo nvidia-xconfig --preserve-busid --enable-all-gpus --connected-monitor=DFP-0,DFP-1,DFP-2,DFP-3
        # Restart the X server for the changes to take effect
        sudo systemctl isolate multi-user.target
        sudo systemctl isolate graphical.target
    else
        # CPU SUPPORT
        # On non-GPU Linux servers: Dummy driver allows the X server to run with a virtual framebuffer when no real GPU is present.
        sudo yum install xorg-x11-drv-dummy -y
        # On non-GPU
        sudo bash -c 'cat >> /etc/X11/xorg.conf <<HERE
cat Section "Device"
Identifier "DummyDevice"
Driver "dummy"
Option "ConstantDPI" "true"
Option "IgnoreEDID" "true"
Option "NoDDC" "true"
VideoRam 2048000
EndSection

Section "Monitor"
    Identifier "DummyMonitor"
    HorizSync   5.0 - 1000.0
    VertRefresh 5.0 - 200.0
    Modeline "1920x1080" 23.53 1920 1952 2040 2072 1080 1106 1108 1135
    Modeline "1600x900" 33.92 1600 1632 1760 1792 900 921 924 946
    Modeline "1440x900" 30.66 1440 1472 1584 1616 900 921 924 946
    ModeLine "1366x768" 72.00 1366 1414 1446 1494  768 771 777 803
    Modeline "1280x800" 24.15 1280 1312 1400 1432 800 819 822 841
    Modeline "1024x768" 18.71 1024 1056 1120 1152 768 786 789 807
EndSection

Section "Screen"
    Identifier "DummyScreen"
    Device "DummyDevice"
    Monitor "DummyMonitor"
    DefaultDepth 24
    SubSection "Display"
        Viewport 0 0
        Depth 24
        Modes "1920x1080" "1600x900" "1440x900" "1366x768" "1280x800" "1024x768"
        virtual 1920 1080
    EndSubSection
EndSection
HERE'
        sudo systemctl isolate multi-user.target
    fi
}


if [[ $kernel_version == *microsoft* ]]; then

# FIXME: Replace by (below) when license server is working
#     <LicenseFile>27002@${resource_privateIp}</LicenseFile>
# Rewrite config file
cat > "/c/Program Files/Penguin Computing/Scyld Cloud Workstation/scyld-cloud-workstation.xml" << END
<config>
  <Server>
    <Keyboard>
      <LocalhostAutoAssign>true</LocalhostAutoAssign>
    </Keyboard>
    <!-- <AutoLock>false</AutoLock> -->
    <!-- <IdleUserTimeout>120</IdleUserTimeout> -->
    <LicenseFile>scyld-cloud-workstation.lic</LicenseFile>
    <!-- <LocalCursor>true</LocalCursor> -->
    <LogLevel>debug</LogLevel>
    <PathPrefix></PathPrefix>
    <Port>${servicePort}</Port>
    <Security>
      <SameOriginHeaders>disabled</SameOriginHeaders>
    </Security>
    <RedirectHTTPPort>false</RedirectHTTPPort>
    <Secure>false</Secure>
    <!-- <VideoSource>auto</VideoSource> -->
    <Audio>
      <!-- <Enabled>true</Enabled> -->
    </Audio>
    <Auth>
      <!-- <MinPasswordLength>6</MinPasswordLength> -->
      <!-- <OSAuthEnabled>true</OSAuthEnabled> -->
      <Username>admin</Username>
      <ScyldCloudAuth>
        <!-- <URL></URL> -->
        <Allow>
          <!-- <Username></Username> -->
        </Allow>
        <Deny>
          <!-- <Username></Username> -->
        </Deny>
      </ScyldCloudAuth>
        <Enabled>false</Enabled>
    </Auth>
    <Broker>
      <Username>broker</Username>
    </Broker>
    <Video>
      <!-- <MaxHeight>1440</MaxHeight> -->
      <!-- <MaxWidth>2560</MaxWidth> -->
      <Encoding>
        <H264>
          <!-- <AvgBitRate>1280x720=3000k,1920x1080=6000k</AvgBitRate> -->
          <!-- <MaxFrameRate>30</MaxFrameRate> -->
        </H264>
      </Encoding>
    </Video>
  </Server>
  <openSSL>
    <server>
      <certificateFile>defaultCert.pem</certificateFile>
      <privateKeyFile>defaultKey.pem</privateKeyFile>
      <!-- <requireTLSv1_2>true</requireTLSv1_2> -->
      <invalidCertificateHandler>
        <!-- <name>RejectCertificateHandler</name> -->
      </invalidCertificateHandler>
      <privateKeyPassphraseHandler>
        <options>
          <!-- <password>secretsecret</password> -->
        </options>
      </privateKeyPassphraseHandler>
    </server>
  </openSSL>
</config>
END

echo "starting SCW on port $servicePort"

while true; do
    check_logs=$(cat "/c/Program Files/Penguin Computing/Scyld Cloud Workstation/log/scyld-cloud-workstation.log" | grep "port ${servicePort}")
    if [ -z "${check_logs}" ]; then
        echo "Restarting Service"
        # Stop SCW service
        "/c/Program Files/Penguin Computing/Scyld Cloud Workstation/bin/scyld-cloud-workstation.exe" /service=stop
        # Start SCW service
        "/c/Program Files/Penguin Computing/Scyld Cloud Workstation/bin/scyld-cloud-workstation.exe" /service=start
    else
        break
    fi
    sleep 5
done

cat "/c/Program Files/Penguin Computing/Scyld Cloud Workstation/log/service.log"
cat "/c/Program Files/Penguin Computing/Scyld Cloud Workstation/log/scyld-cloud-workstation.log"

else
#########
# LINUX #
#########
configure_X_server
# FIXME: Replace by (below) when license server is working
#     <LicenseFile>27002@${resource_privateIp}</LicenseFile>
# Rewrite config file
cat > "./scyld-cloud-workstation.xml" << END
<config>
  <Server>
    <Keyboard>
      <LocalhostAutoAssign>true</LocalhostAutoAssign>
    </Keyboard>
    <!-- <AutoLock>false</AutoLock> -->
    <!-- <IdleUserTimeout>120</IdleUserTimeout> -->
    <LicenseFile>scyld-cloud-workstation.lic</LicenseFile>
    <!-- <LocalCursor>true</LocalCursor> -->
    <LogLevel>debug</LogLevel>
    <PathPrefix></PathPrefix>
    <Port>${servicePort}</Port>
    <Security>
      <SameOriginHeaders>disabled</SameOriginHeaders>
    </Security>
    <RedirectHTTPPort>false</RedirectHTTPPort>
    <Secure>false</Secure>
    <!-- <VideoSource>auto</VideoSource> -->
    <Audio>
      <!-- <Enabled>true</Enabled> -->
    </Audio>
    <Auth>
      <!-- <MinPasswordLength>6</MinPasswordLength> -->
      <!-- <OSAuthEnabled>true</OSAuthEnabled> -->
      <Username>admin</Username>
      <ScyldCloudAuth>
        <!-- <URL></URL> -->
        <Allow>
          <!-- <Username></Username> -->
        </Allow>
        <Deny>
          <!-- <Username></Username> -->
        </Deny>
      </ScyldCloudAuth>
        <Enabled>false</Enabled>
    </Auth>
    <Broker>
      <Username>broker</Username>
    </Broker>
    <Video>
      <!-- <MaxHeight>1440</MaxHeight> -->
      <!-- <MaxWidth>2560</MaxWidth> -->
      <Encoding>
        <H264>
          <!-- <AvgBitRate>1280x720=3000k,1920x1080=6000k</AvgBitRate> -->
          <!-- <MaxFrameRate>30</MaxFrameRate> -->
        </H264>
      </Encoding>
    </Video>
  </Server>
  <openSSL>
    <server>
      <certificateFile>defaultCert.pem</certificateFile>
      <privateKeyFile>defaultKey.pem</privateKeyFile>
      <!-- <requireTLSv1_2>true</requireTLSv1_2> -->
      <invalidCertificateHandler>
        <!-- <name>RejectCertificateHandler</name> -->
      </invalidCertificateHandler>
      <privateKeyPassphraseHandler>
        <options>
          <!-- <password>secretsecret</password> -->
        </options>
      </privateKeyPassphraseHandler>
    </server>
  </openSSL>
</config>
END

sudo cp ./scyld-cloud-workstation.xml /opt/scyld-cloud-workstation/bin/

echo "starting SCW on port $servicePort"

sudo systemctl restart scyld-cloud-workstation

sudo cat "/opt/scyld-cloud-workstation/bin/service.log"
sudo cat "/opt/scyld-cloud-workstation/bin//scyld-cloud-workstation.log"


fi

sleep 99999
