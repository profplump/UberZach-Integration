#!/usr/bin/python
import os
import sys
import array
import string
from ola.ClientWrapper import ClientWrapper

wrapper = None
dim = False
dimTick = 0
dimTime = 0
numTicks = 0

# Wrapper callback
def DmxSent(state):
  # Stop on errors
  if not state.Succeeded():
    wrapper.Stop()
  
  # Only run one command if we're setting
  if not dim:
    wrapper.Stop()
  
  # Stop when we're done dimming
  if dim and dimTick >= numTicks:
    wrapper.Stop()

# Pick a universe (0, or as specified in the environment)
universe = 0
if 'UNIVERSE' in os.environ:
  universe = int(os.environ['UNIVERSE'])

# Pick a tick interval (50ms, or as specified in the environment)
interval = 50
if 'INTERVAL' in os.environ:
  universe = int(os.environ['INTERVAL'])

# Choose direct-set or dimming
dim = False
if 'dim' in string.lower(sys.argv[0]):
  dim = True

# If we are dimming, parse the command line into 3-part blocks
# Otherwise just collect the intensities directly
cmdData = [];
if dim:
  dimTime = int(sys.argv[1])
  numTicks = dimTime / interval

  for i in range(2, len(sys.argv), 2):
      dimData = array.array('I')
      dimData.append(int(sys.argv[i]))
      dimData.append(int(sys.argv[i + 1]))
      cmdData.append(dimData)
else:
  for i in range(1, len(sys.argv)):
    cmdData.append(int(sys.argv[i]))

def SendDMXFrame():
  # Re-schedule ourselves in interval ms (do this first to keep the timing consistent)
  if dim:
    wrapper.AddEvent(interval, SendDMXFrame)
  
  # Eventually we need an array of intesnty bytes for each channel
  data = array.array('B')

  # Calculate intensities
  if dim:
    global dimTick
    dimTick += 1
    
    for i in cmdData:
      totalRange = i[1] - i[0]
      delta = float(totalRange) / float(numTicks) * float(dimTick)
      data.append(int(i[0] + delta))

  else:
    # Copy each intensity level from the command line
    for i in cmdData:
      data.append(i)
  
  # Send
  wrapper.Client().SendDmx(universe, data, DmxSent)

# Send the DMX command
wrapper = ClientWrapper()
wrapper.AddEvent(interval, SendDMXFrame)
wrapper.Run()
