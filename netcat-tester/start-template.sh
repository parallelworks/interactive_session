# Runs via ssh + sbatch
while true; do
    #nc -klv -p __servicePort__ -c 'echo -e \"HTTP/1.1 200 OK\r\n"'$(date)'"\r\n\r\n<h1>hello world from "'$(hostname)'"</h1>\"'
    nc -klv -p __servicePort__ -c  'echo -e "HTTP/1.1 200 OK\r\n"$(date)"\r\n\r\n<h1>hello world from" $(hostname)"</h1>"'
done