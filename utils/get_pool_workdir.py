import sys, json
import pool_api

if __name__ == '__main__':
    pool_info = pool_api.get_pool_info(sys.argv[1])
    print(json.loads(pool_info['coasterproperties'])['workdir'])
