import numpy as np
from os import environ

# http://stackoverflow.com/questions/2741399/python-pyximporting-a-pyx-that-depends-on-a-native-library
# Link to math library without having to write setup.py
environ['LDFLAGS'] = '-Lm -lm'

# Automatic Cython file compilation
import pyximport
pyximport.install(setup_args={"include_dirs":np.get_include()},
    reload_support = True)

from mpi4py import MPI
from multiprocessing.pool import ThreadPool

from parse_input import parse_input
from sim import go

def prepare_input(num_threads, comm, config_file):

    # get simulation inputs from configuration file
    lambd, mu, rho, min_x, max_x, min_y, max_y, min_z, max_z, N_x, N_y, N_z, t_0, t_f, N_t = parse_input(config_file)

    # Grid spacing in each dimension
    dx = (max_x - min_x) / N_x
    dy = (max_y - min_y) / N_y
    dz = (max_z - min_z) / N_z

    # Timestep
    dt = (t_f - t_0) / N_t

    # Grid size in each direction
    L_x = np.float64(max_x) - np.float64(min_x)
    L_y = np.float64(max_y) - np.float64(min_y)
    L_z = np.float64(max_z) - np.float64(min_z)

    params = []
    for param in [comm, N_x, N_y, N_z, L_x, L_y, L_z, dx, dy, dz, dt, mu, rho, lambd, t_0, t_f]:
        params.append([param] * num_threads)

    params = tuple(params)

    return zip(range(num_threads), *params)


def parallel_sim(config_file, num_threads=1):

    comm = MPI.COMM_WORLD
    pool = ThreadPool(num_threads)

    # send work to all the threads
    pool.map(go, prepare_input(num_threads, comm, config_file), chunksize=1)

if __name__ == '__main__':

    parallel_sim('test.conf', 4)
