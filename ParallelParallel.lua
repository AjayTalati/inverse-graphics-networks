require 'nn'
LL = require 'LL'
moses = require 'moses'
require 'parallel'

local ParallelParallel, parent = torch.class('nn.ParallelParallel', 'nn.Container')

function moduleWrapper()
  require 'nn'
  require 'ACR'
  require 'INTM'
  require 'Bias'

  torch.setnumthreads(1)

  local mod = nil
  while true do
    m = parallel.yield()
    if m == 'break' then break end

    local message = parallel.parent:receive()
    local messageType = message[1]
    local data = message[2]

    if messageType == 'module' then
      mod = data
      for i, m in pairs(mod:findModules('nn.ACR')) do
        m:makeThreads()
      end
    elseif messageType == 'updateOutput' then
      parallel.parent:send(mod:updateOutput(data))
    elseif messageType == 'updateGradInput' then
      parallel.parent:send(mod:updateGradInput(data[1], data[2]))
    elseif messageType == 'accGradParameters' then
      mod:accGradParameters(data[1], data[2], data[3])
    elseif messageType == 'accUpdateGradParameters' then
      mod:accUpdateGradParameters(data[1], data[2], data[3])
    elseif messageType == 'zeroGradParameters' then
      mod:zeroGradParameters()
    elseif messageType == 'updateParameters' then
      mod:updateParameters(data)
    elseif messageType == 'training' then
      mod:training()
    elseif messageType == 'evaluate' then
      mod:evaluate()
    elseif messageType == 'share' then
      mod:evaluate(data[1], data[2])
    elseif messageType == 'reset' then
      mod:reset(data)
    end
  end
end

function ParallelParallel:__init(inputDimension,outputDimension)
  parent.__init(self)
  self.modules = {}
  self.size = torch.LongStorage()
  self.inputDimension = inputDimension
  self.outputDimension = outputDimension
  self.childThreads = {}

  -- make self.childThreads act just like parallel.children
  parallel._fill(self.childThreads)

  -- self.ll = LL:new(nThreads, {'nn', 'ParallelParallel', 'Bias', 'ACR', 'INTM'})
end

function ParallelParallel:add(mod)
  local child = parallel.fork()
  child:exec(moduleWrapper)
  table.insert(self.childThreads, child)

  local localmod = {}
  setmetatable(localmod, {__tostring__ = function () return tostring(mod) end})
  table.insert(self.modules, localmod)
  child:join()
  child:send({'module', mod})
  -- os.execute("sleep " .. tonumber(1))
  return self
end

function ParallelParallel:updateOutput(input)
  local nModule=input:size(self.inputDimension)

  -- parallel.print(parallel.children)
  -- parallel.print("issuing join")

  -- for i = 1, #self.modules do
  --   self.childThreads[i]:join()
  --   -- parallel.print("sending module")
  --   self.childThreads[i]:send({'module', self.modules[i]})
  -- end

  -- parallel.print("issuing join #2")
  -- parallel.children:join()
  for i = 1, #self.modules do
    self.childThreads[i]:join()
    local currentInput = input:select(self.inputDimension,i)
    -- parallel.print("sending updateOutput")
    self.childThreads[i]:send({'updateOutput', currentInput})
  end

  local outputs = self.childThreads:receive()

  -- local inputDimension = self.inputDimension
  -- local runModule = function(inputTensor, i, module)
  --    local currentInput = inputTensor:select(inputDimension,i)
  --    return module:updateOutput(currentInput)
  -- end
  -- local outputs = self.ll:pmap_mut(self.modules, moses.bind(runModule, input))

  for i = 1, #outputs do
    self.modules[i].output = outputs[i]
    local currentOutput = outputs[i]
    local outputSize = currentOutput:size(self.outputDimension)

    if i == 1 then
      self.size:resize(currentOutput:dim()):copy(currentOutput:size())
    else
      self.size[self.outputDimension] = self.size[self.outputDimension] + outputSize
    end

  end
  self.output:resize(self.size)

  local offset = 1
  for i=1,nModule do
    local currentOutput = self.modules[i].output
    local outputSize = currentOutput:size(self.outputDimension)
    self.output:narrow(self.outputDimension, offset, outputSize):copy(currentOutput)
    offset = offset + currentOutput:size(self.outputDimension)
  end
  return self.output
end

function ParallelParallel:updateGradInput(input, gradOutput)
  local nModule=input:size(self.inputDimension)
  self.gradInput:resizeAs(input)
  local offset = 1

  -- for i = 1, #self.modules do
  --   self.childThreads[i]:join()
  --   self.childThreads[i]:send({'module', self.modules[i]})
  -- end

  for i = 1, #self.modules do
    self.childThreads[i]:join()
    local currentInput = input:select(self.inputDimension,i)
    local currentOutput = self.modules[i].output
    local outputSize = currentOutput:size(self.outputDimension)
    local currentGradOutput = gradOutput:narrow(self.outputDimension, offset, outputSize)
    self.childThreads[i]:send({'updateGradInput', {currentInput, currentGradOutput}})
  end

  local gradInputs = parallel.children:receive()

  for i=1,nModule do
    self.modules[i].gradInput = gradInputs[i]
    local currentGradInput = gradInputs[i]
    local currentOutput = self.modules[i].output
    local outputSize = currentOutput:size(self.outputDimension)
    self.gradInput:select(self.inputDimension,i):copy(currentGradInput)
    offset = offset + outputSize
  end
  return self.gradInput
end

function ParallelParallel:accGradParameters(input, gradOutput, scale)
  local nModule=input:size(self.inputDimension)

  local offset = 1
  for i=1,nModule do
    local mod = self.modules[i]
    local currentOutput = mod.output
    local outputSize = currentOutput:size(self.outputDimension)

    self.childThreads[i]:join()
    self.childThreads[i]:send({
      'accGradParameters',
      {input:select(self.inputDimension,i),
        gradOutput:narrow(self.outputDimension, offset,outputSize),
        scale}})

    -- mod:accGradParameters(
    --   input:select(self.inputDimension,i),
    --   gradOutput:narrow(self.outputDimension, offset,outputSize),
    --   scale
    -- )

    offset = offset + outputSize
  end
end

function ParallelParallel:accUpdateGradParameters(input, gradOutput, lr)
  local nModule=input:size(self.inputDimension)

  local offset = 1
  for i=1,nModule do
    local mod = self.modules[i];
    local currentOutput = mod.output

    self.childThreads[i]:join()
    self.childThreads[i]:send({
      'accUpdateGradParameters',
      {input:select(self.inputDimension,i),
        gradOutput:narrow(self.outputDimension, offset,
                   currentOutput:size(self.outputDimension)),
        lr}})

    -- mod:accUpdateGradParameters(
    --    input:select(self.inputDimension,i),
    --    gradOutput:narrow(self.outputDimension, offset,
    --                currentOutput:size(self.outputDimension)),
    --    lr)

    offset = offset + currentOutput:size(self.outputDimension)
  end
end

function ParallelParallel:zeroGradParameters()
  for i = 1, #self.modules do
    self.childThreads[i]:join()
    self.childThreads[i]:send({'zeroGradParameters'})
  end
end

function ParallelParallel:training()
  for i = 1, #self.modules do
    self.childThreads[i]:join()
    self.childThreads[i]:send({'training'})
  end
end

function ParallelParallel:evaluate()
  for i = 1, #self.modules do
    self.childThreads[i]:join()
    self.childThreads[i]:send({'evaluate'})
  end
end

function ParallelParallel:reset(stdv)
  for i = 1, #self.modules do
    self.childThreads[i]:join()
    self.childThreads[i]:send({'reset', stdv})
  end
end

function ParallelParallel:updateParameters(learningRate)
  for i = 1, #self.modules do
    self.childThreads[i]:join()
    self.childThreads[i]:send({'updateParameters', learningRate})
  end
end

function ParallelParallel:share(mlp, ...)
  for i = 1, #self.modules do
    self.childThreads[i]:join()
    self.childThreads[i]:send({'share', {mlp.modules[i], ...}})
  end
end

function ParallelParallel:__tostring__()
  local tab = '  '
  local line = '\n'
  local next = '  |`-> '
  local ext = '  |    '
  local extlast = '       '
  local last = '   ... -> '
  local str = torch.type(self)
  str = str .. ' {' .. line .. tab .. 'input'
  for i=1,#self.modules do
    if i == self.modules then
      str = str .. line .. tab .. next .. '(' .. i .. '): ' .. tostring(self.modules[i]):gsub(line, line .. tab .. extlast)
    else
      str = str .. line .. tab .. next .. '(' .. i .. '): ' .. tostring(self.modules[i]):gsub(line, line .. tab .. ext)
    end
  end
  str = str .. line .. tab .. last .. 'output'
  str = str .. line .. '}'
  return str
end