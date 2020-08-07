import pyro
from pyro.distributions import Exponential

def sample(site_name, dist):
    return pyro.sample(site_name, dist)

def observe(site_name, dist, obs):
    pyro.sample(site_name, dist, obs = obs)
    
def factor(site_name, x):
    pyro.sample(site_name, Exponential(1), obs=-x)
    