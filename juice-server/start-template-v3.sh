# Runs via ssh + sbatch
set -x

if [ -z ${service_parent_install_dir} ]; then
    service_parent_install_dir=${HOME}/pw/software
fi

${service_parent_install_dir}/JuiceServer/agent -address 0.0.0.0:${service_port}


"""
$ ./agent --help
Usage of ./agent:
  -access-token string
    	The access token to use when connecting to the controller
  -address string
    	The IP address and port to use for listening for client connections (default "0.0.0.0:43210")
  -auth-audience string
    	The audience used for validating jwt tokens
  -auth-domain string
    	The domain used for validating jwt tokens
  -cert-file string
    	
  -controller string
    	The IP address and port of the controller
  -disable-gpu-metrics
    	
  -enable-token-validation
    	Enable token validation
  -expose string
    	The IP address and port to expose through the controller for clients to see. The value is not checked for correctness.
  -generate-cert
    	Generates a certificate for https
  -gpu-metrics-interval-ms uint
    	 (default 1000)
  -juice-path string
    	
  -key-file string
    	
  -labels string
    	Comma separated list of key=value pairs
  -log-file string
    	
  -log-level string
    	Sets the maximum level of output [Fatal, Error, Warning, Info (Default), Debug, Trace] (default "info")
  -quiet
    	Disables all logging output
  -taints string
    	Comma separated list of key=value pairs
  -version
    	Prints the version and exits

"""

