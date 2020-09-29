from runtimes.pyro.distributions import *
from runtimes.pyro.dppllib import sample, param, observe, factor, array, zeros, ones, matmul, true_divide, floor_divide, transpose, dtype_long, dtype_float, register_network

def convert_inputs(inputs):
    K = inputs['K']
    N = inputs['N']
    x = array(inputs['x'], dtype=dtype_float)
    y = array(inputs['y'], dtype=dtype_float)
    return { 'K': K, 'N': N, 'x': x, 'y': y }

def model(*, K, N, x, y):
    # Parameters
    beta = sample('beta', improper_uniform(shape=[K]))
    # Model
    observe('y__1', normal(matmul(x, beta), 1), y)

