from runtimes.pyro.distributions import *
from runtimes.pyro.dppllib import sample, param, observe, factor, array, zeros, ones, empty, matmul, true_divide, floor_divide, transpose, dtype_long, dtype_float

def convert_inputs(inputs):
    
    return {  }

def model():
    # Parameters
    theta = sample('theta', improper_uniform(shape=[]))
    # Model
    factor('expr__1', - array(0.5, dtype=dtype_float) * (theta - array(1000.0, dtype=dtype_float)) * (theta - array(1000.0, dtype=dtype_float)))


