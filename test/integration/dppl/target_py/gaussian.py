from runtimes.pyro.distributions import *
from runtimes.pyro.dppllib import sample, param, observe, factor, array, zeros, ones, empty, matmul, true_divide, floor_divide, transpose, dtype_long, dtype_float

def convert_inputs(inputs):
    
    return {  }

def model():
    # Parameters
    theta = sample('theta', improper_uniform(shape=[]))
    # Model
    observe('theta__1', normal(array(1000.0, dtype=dtype_float),
                               array(1.0, dtype=dtype_float)), theta)

