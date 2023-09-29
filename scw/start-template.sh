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

if  ! [ -z $(which gnome-session) ]; then
    gnome-session &
    echo $! > ${resource_jobdir}/service.pid
elif ! [ -z $(which mate-session) ]; then
    mate-session &
    echo $! > ${resource_jobdir}/service.pid
elif ! [ -z $(which xfce4-session) ]; then
    xfce4-session &
    echo $! > ${resource_jobdir}/service.pid
elif ! [ -z $(which icewm-session) ]; then
    # FIXME: Code below fails to launch desktop session
    #        Use case in onyx automatically launches the session when visual apps are launched
    echo Found icewm-session
    #icewm-session &
    #echo $! > ${resource_jobdir}/service.pid
elif ! [ -z $(which gnome) ]; then
    gnome &
    echo $! > ${resource_jobdir}/service.pid
else
    # Exit script here
    #displayErrorMessage "ERROR: No desktop environment was found! Tried gnome-session, mate-session, xfce4-session and gnome"
    # The lines below do not run
    echo "WARNING: vnc desktop not found!"
    echo "Attempting to install a desktop environment"
    # Following https://owlhowto.com/how-to-install-xfce-on-centos-7/
    # Install EPEL release
    sudo -n yum install epel-release -y
    # Install Window-x system
    sudo -n yum groupinstall "X Window system" -y
    # Install XFCE
    sudo -n yum groupinstall "Xfce" -y
    if ! [ -z $(which xfce4-session) ]; then
        displayErrorMessage "ERROR: No desktop environment was found! Tried gnome-session, mate-session, xfce4-session and gnome"
    fi
    # Start GUI
    xfce4-session &
    echo $! > ${resource_jobdir}/service.pid
fi


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
