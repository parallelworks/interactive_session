set -x

# FIXME: Replace by (below) when license server is working
#     <LicenseFile>27002@${resource_privateIp}</LicenseFile>
# Rewrite config file
cat > "/c/Program Files/Penguin Computing/Scyld Cloud Workstation/scyld-cloud-workstation.xml" << END
<config>
  <Server>
    <!-- <AutoLock>false</AutoLock> -->
    <!-- <IdleUserTimeout>120</IdleUserTimeout> -->
    <LicenseFile>scyld-cloud-workstation.lic</LicenseFile>
    <!-- <LocalCursor>true</LocalCursor> -->
    <!-- <LogLevel>information</LogLevel> -->
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

sleep 99999
