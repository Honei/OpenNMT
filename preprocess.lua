local dict = require 's2sa.dict'
local file_reader = require 's2sa.file_reader'
local parallel_file_reader = require 's2sa.parallel_file_reader'
local table_utils = require 's2sa.table_utils'
local opt_utils = require 's2sa.opt_utils'

local cmd = torch.CmdLine()

cmd:option('-train_src_file', '', [[Path to the training source data]])
cmd:option('-train_targ_file', '', [[Path to the training target data]])
cmd:option('-valid_src_file', '', [[Path to the validation source data]])
cmd:option('-valid_targ_file', '', [[Path to the validation target data]])

cmd:option('-output_file', '', [[Output file for the prepared data]])

cmd:option('-src_vocab_size', 50000, [[Size of the source vocabulary]])
cmd:option('-targ_vocab_size', 50000, [[Size of the target vocabulary]])

cmd:option('-seq_length', 50, [[Maximum sequence length]])
cmd:option('-shuffle', 1, [[Suffle data]])

cmd:option('-report_every', 100000, [[Report status every this many sentences]])

local opt = cmd:parse(arg)

local function make_vocabulary(filename, size)
  local vocab = dict.new({'<blank>', '<unk>', '<s>', '</s>'})
  local reader = file_reader.new(filename)

  while true do
    local sent = reader:next()
    if sent == nil then
      break
    end
    for i = 1, #sent do
      vocab:add(sent[i])
    end
  end

  local original_size = #vocab

  reader:close()
  vocab = vocab:prune(size)

  print('Created dictionary of size ' .. #vocab .. ' (pruned from ' .. original_size .. ')')

  return vocab
end

local function make_sentence(sent, dictionary, start_symbols)
  local vec = {}

  if start_symbols == true then
    table.insert(vec, dictionary:lookup('<s>'))
  end

  for i = 1, #sent do
    local idx = dictionary:lookup(sent[i])
    if idx == nil then
      idx = dictionary:lookup('<unk>')
    end
    table.insert(vec, idx)
  end

  if start_symbols == true then
    table.insert(vec, dictionary:lookup('</s>'))
  end

  return torch.IntTensor(vec)
end

local function make_data(src_file, targ_file, src_dict, targ_dict)
  local src = {}
  local targ = {}
  local sizes = {}

  local count = 0
  local ignored = 0

  local parallel_reader = parallel_file_reader.new(src_file, targ_file)

  while true do
    local src_tokens, targ_tokens = parallel_reader:next()
    if src_tokens == nil or targ_tokens == nil then
      break
    end
    if #src_tokens > 0 and #src_tokens <= opt.seq_length
    and #targ_tokens > 0 and #targ_tokens <= opt.seq_length then
      table.insert(src, make_sentence(src_tokens, src_dict, false))
      table.insert(targ, make_sentence(targ_tokens, targ_dict, true))
      table.insert(sizes, #src_tokens)
    else
      ignored = ignored + 1
    end
    count = count + 1
    if count % opt.report_every == 0 then
      print('... ' .. count .. ' sentences prepared')
    end
  end

  if opt.shuffle == 1 then
    print('... shuffling sentences')
    local perm = torch.randperm(#src)
    src = table_utils.reorder(src, perm)
    targ = table_utils.reorder(targ, perm)
    sizes = table_utils.reorder(sizes, perm)
  end

  print('... sorting sentences by size')
  local _, perm = torch.sort(torch.Tensor(sizes))
  src = table_utils.reorder(src, perm)
  targ = table_utils.reorder(targ, perm)

  print('Prepared ' .. #src .. ' sentences (' .. ignored .. ' ignored due to length == 0 or > ' .. opt.seq_length .. ')')

  return src, targ
end

local function main()
  local required_options = {
    "train_src_file",
    "train_targ_file",
    "valid_src_file",
    "valid_targ_file",
    "output_file"
  }

  if not opt_utils.require_options(opt, "preprocess.lua", required_options) then
    return
  end

  print('Building source vocabulary...')
  local src_dict = make_vocabulary(opt.train_src_file, opt.src_vocab_size)
  print('')

  print('Building target vocabulary...')
  local targ_dict = make_vocabulary(opt.train_targ_file, opt.targ_vocab_size)
  print('')

  print('Preparing training data...')
  local train_src, train_targ = make_data(opt.train_src_file, opt.train_targ_file, src_dict, targ_dict)
  print('')

  print('Preparing validation data...')
  local valid_src, valid_targ = make_data(opt.valid_src_file, opt.valid_targ_file, src_dict, targ_dict)
  print('')

  local data = {}
  data.train = {
    ["src"] = train_src,
    ["targ"] = train_targ
  }
  data.valid = {
    ["src"] = valid_src,
    ["targ"] = valid_targ
  }
  data.src_dict = src_dict
  data.targ_dict = targ_dict

  print('Saving data to ' .. opt.output_file .. '...')
  torch.save(opt.output_file, data)
end

main()