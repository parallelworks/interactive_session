# Initialize cancel script
echo '#!/bin/bash' > cancel.sh
chmod +x cancel.sh

echo "Starting nginx wrapper on service port ${service_port}"

# Write config file
cat >> config.conf <<HERE
server {
 listen ${service_port};
 server_name _;
 index index.html index.htm index.php;
 add_header 'Access-Control-Allow-Methods' 'GET, POST, OPTIONS';
 add_header 'Access-Control-Allow-Headers' 'Authorization,Content-Type,Accept,Origin,User-Agent,DNT,Cache-Control,X-Mx-ReqToken,Keep-Alive,X-Requested-With,If-Modified-Since';
 add_header X-Frame-Options "ALLOWALL";
 client_max_body_size 1000M;
 location / {
     proxy_pass http://127.0.0.1:${service_existing_port};
     proxy_http_version 1.1;
       proxy_set_header Upgrade \$http_upgrade;
       proxy_set_header Connection "upgrade";
       proxy_set_header X-Real-IP \$remote_addr;
       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
       proxy_set_header Host \$http_host;
       proxy_set_header X-NginX-Proxy true;
 }

 location /api/ {
     proxy_pass http://127.0.0.1:8000;
     proxy_http_version 1.1;
       proxy_set_header Upgrade \$http_upgrade;
       proxy_set_header Connection "upgrade";
       proxy_set_header X-Real-IP \$remote_addr;
       proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
       proxy_set_header Host \$http_host;
       proxy_set_header X-NginX-Proxy true;
 }
}
HERE

container_name="nginx-${service_port}"
# Remove container when job is canceled
echo "sudo docker stop ${container_name}" >> cancel.sh
echo "sudo docker rm ${container_name}" >> cancel.sh
# Start container
sudo service docker start
touch empty
sudo docker run  -d --name ${container_name} \
    -v $PWD/config.conf:/etc/nginx/conf.d/config.conf \
    -v $PWD/empty:/etc/nginx/conf.d/default.conf \
    --network=host nginxinc/nginx-unprivileged:1.25.3

# Print logs
sudo docker logs ${container_name}

# build and serve the app
docker compose run --service-ports --entrypoint bash  ngencerf-ui
export NGENCERF_BASE_URL=/me/54238/api/
npm run generate
npx serve .output/public/

# Notify platform that service is running
${sshusercontainer} "${pw_job_dir}/utils/notify.sh Running"

sleep infinity