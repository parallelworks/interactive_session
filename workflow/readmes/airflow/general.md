## Airflow Interactive Session
This workflow starts an [Airflow server](https://airflow.apache.org/) [interactive session](https://github.com/parallelworks/interactive_session/blob/main/README-v3.md).


### Installation
Specify Airflow's home directory in the input form. By default, it is set to `__WORKDIR__/pw/airflow`, where `__WORKDIR__` is the user's home directory.

If the specified directory does not exist, the workflow installs Airflow using pip in a Miniconda environment. The Miniconda installation directory defaults to:
```
__WORKDIR__/pw/software/miniconda3-<basename of Airflow's home directory>

```

For example, if Airflow's home directory is `__WORKDIR__/pw/airflow`, Miniconda will be installed at:
```
__WORKDIR__/pw/software/miniconda3-airflow
```


### Dags
Files in `./airflow-host/dags/` are copied to Airflow’s DAGs folder and will appear in the Airflow UI.


