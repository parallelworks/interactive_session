set -x

kernel_version=$(uname -r | tr '[:upper:]' '[:lower:]')

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
    <Port>${service_port}</Port>
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

echo "starting SCW on port $service_port"

while true; do
    check_logs=$(cat "/c/Program Files/Penguin Computing/Scyld Cloud Workstation/log/scyld-cloud-workstation.log" | grep "port ${service_port}")
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

if ! [ -d "/opt/scyld-cloud-workstation" ]; then
    echo "Installing Scyld Cloud Workstation"
    wget https://updates.penguincomputing.com/scw/download/el7/x86_64/latest/scyld-cloud-workstation-12.3.0-1.el7.x86_64.rpm .
    sudo rpm -i scyld-cloud-workstation-12.3.0-1.el7.x86_64.rpm
    sudo cp /contrib/${USER}/scyld-cloud-workstation.lic /opt/scyld-cloud-workstation/bin/
fi

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
    <Port>${service_port}</Port>
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

# CONFIGURE X SERVER
if nvidia-smi &>/dev/null; then
    echo "Configuring X server for GPUs"
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
    sudo nvidia-xconfig --preserve-busid --enable-all-gpus
    # If you're using a G3 or G4 Amazon EC2 instance and you want to use a multi-monitor console session
    # sudo nvidia-xconfig --preserve-busid --enable-all-gpus --connected-monitor=DFP-0,DFP-1,DFP-2,DFP-3
    # Restart the X server for the changes to take effect
    sudo systemctl isolate multi-user.target
    sudo systemctl isolate graphical.target
else
    displayErrorMessage "ERROR: Linux version of Scyld Cloud Workstation is only supported in nodes with GPUs"
fi


echo; echo "Enabling autologin"
cat > "custom.conf" << END
# GDM configuration storage

[daemon]
AutomaticLogin=${USER}
AutomaticLoginEnable=True

[security]

[xdmcp]

[chooser]

[debug]
# Uncomment the line below to turn on debugging
#Enable=true

END

sudo cp custom.conf /etc/gdm/custom.conf
sudo systemctl restart gdm


echo; echo "starting SCW on port $service_port"

sudo systemctl restart scyld-cloud-workstation

sudo cat "/opt/scyld-cloud-workstation/bin/service.log"
sudo cat "/opt/scyld-cloud-workstation/bin//scyld-cloud-workstation.log"


fi

# Notify platform that service is running
${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

sleep 999999999
