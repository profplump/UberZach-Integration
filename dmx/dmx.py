#!/opt/local/bin/python2.7

# Append the path to help find our OLA packages
import sys
sys.path.append('/opt/local/lib/python2.7/site-packages')
sys.path.append('/opt/local/Library/Frameworks/Python.framework/Versions/2.7/lib/python2.7/site-packages')

import os
import time
import array
import select
import socket
import string
import subprocess
from ola.ClientWrapper import ClientWrapper

# ====================================
# Defaults
# ====================================
interval = 50
universe = 0
max_value = 255
max_delay = 300000
max_channels = 255
min_delta = 0.005

# ====================================
# Environment
# ====================================
DEBUG = None
try:
  DEBUG = os.environ['DEBUG']
except NameError:
  DEBUG = None

# ====================================
# Globals
# ====================================
wrapper = None
state = [ 0 ] * max_channels
cmds = { 'value' : [ 0 ] * max_channels, 'ticks' : [ 0 ] * max_channels, 'delay' : [ 0 ] * max_channels }
sock = None
max_mesg_len = 1024

# ====================================
# Wrapper callback -- exit on errors
# ====================================
def DmxSent(state):
  # Stop on errors
  if not state.Succeeded():
    wrapper.Stop()

# ====================================
# Main calculation
# ====================================
def SendDMXFrame():
  # Re-schedule ourselves in interval ms (do this first to keep the timing consistent)
  wrapper.AddEvent(interval, SendDMXFrame)
  
  # Check for new commands
  while (True):
    try:
      cmd = sock.recvfrom(max_mesg_len)[0]
    except socket.error:
      break
    channel, duration, intensity, delay = string.split(cmd, ':')
    try:
      channel = int(channel)
      duration = int(duration)
      intensity = int(intensity)
    except ValueError:
      print 'Invalid command:', cmd
      channel = -1
    try:
      delay = int(delay)
    except ValueError:
      delay = 0
    
    # Save valid commands
    if (channel >= 0 and channel <= max_channels and intensity >= 0 and intensity <= max_value and duration >= 0 and duration <= max_delay and delay >= 0 and delay < max_delay):
      if (channel > 0):
        cmds['value'][channel - 1] = intensity
        cmds['ticks'][channel - 1] = duration / interval
        cmds['delay'][channel - 1] = delay / interval
      else:
        for i in range(len(state)):
          cmds['value'][i] = intensity
          cmds['ticks'][i] = duration / interval
          cmds['delay'][i] = delay / interval
    else:
      print 'Invalid command parameters:', channel, duration, intensity, delay
  
  # Update values for each channel
  for i in range(len(cmds['value'])):
    delta = 0
    if (cmds['value'][i] != state[i]):
      if (cmds['delay'][i] > 0):
        cmds['delay'][i] -= 1
      else:
        diff = cmds['value'][i] - state[i]
        if (cmds['ticks'][i] < 1):
          delta = diff
        else:
          delta = float(diff) / float(cmds['ticks'][i])
        if (abs(delta) < min_delta):
          delta = diff
        state[i] += delta
        cmds['ticks'][i] -= 1
      if (DEBUG):
        print '(', time.time(), ') Channel:', (i + 1)
        print "\tDelay:", cmds['delay'][i], "\tValue:", '%.3f' % state[i], "\tDelta:", '%.3f' % delta, "\tTicks:", cmds['ticks'][i]
    
  # Send all DMX channels
  data = array.array('B')
  for i in range(len(state)):
    data.append(int(state[i]))
  wrapper.Client().SendDmx(universe, data, DmxSent)

# ====================================
# Main
# ====================================

# Pick a universe (default from above, or as specified in the environment)
if 'UNIVERSE' in os.environ:
  universe = int(os.environ['UNIVERSE'])

# Pick a tick interval (default from above, or as specified in the environment)
if 'INTERVAL' in os.environ:
  universe = int(os.environ['INTERVAL'])

# Pick a socket file ($TMPDIR/plexMonitor/DMX.socket, or as specified in the environment)
cmd_file = None
data_dir = None
if 'SOCKET' in os.environ:
  cmd_file = os.environ['SOCKET']
  data_dir = os.dirname(cmd_file)
else:
  proc = subprocess.Popen(['getconf', 'DARWIN_USER_TEMP_DIR'], stdout=subprocess.PIPE, shell=False)
  (tmp_dir, err) = proc.communicate()
  tmp_dir = tmp_dir.strip()
  data_dir = tmp_dir + 'plexMonitor/'
  cmd_file = data_dir + 'DMX.socket'

# Sanity checks
if (not os.path.isdir(data_dir)):
  raise Exception('Bad config: ' + data_dir)

# Open the socket
if (os.path.exists(cmd_file)):
  os.unlink(cmd_file)
sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
sock.bind(cmd_file)
sock.setblocking(0)

# Start the DMX loop
wrapper = ClientWrapper()
wrapper.AddEvent(interval, SendDMXFrame)
wrapper.Run()
