require 'nn'
require 'rnn'
require 'GRUST'
require 'tds'
-- local argcheck = require 'argcheck'

local skipthoughts = {}

skipthoughts.__download = function(dirname)
   os.execute('mkdir -p '..dirname)
   os.execute('wget http://uni_gru.t7 -P '..dirname)
   os.execute('wget http://uni_hashmap.t7 -P '..dirname)
   os.execute('wget http://bi_gru_fwd.t7 -P '..dirname)
   os.execute('wget http://bi_gru_bwd.t7 -P '..dirname)
   os.execute('wget http://bi_hashmap.t7 -P '..dirname)
end

skipthoughts.loadHashmap = function(dirname, mode)
   local mode = mode or 'uni'
   if not paths.dirp(dirname) then
      skipthoughts.__download(dirname)
   end
   return torch.load(paths.concat(dirname, mode..'_hashmap.t7'))
end

skipthoughts.createLookupTable = function(vocab, dirname, mode)
   local hashmap = skipthoughts.loadHashmap(dirname, mode)
   local lookup = nn.LookupTableMaskZero(#vocab, 620)
   for i=1, #vocab do
      if hashmap[vocab[i]] then
         lookup.weight[i+1]:copy(hashmap[vocab[i]]) -- i+1 because 1 is the 0 vector
      else
         print('Warning '..vocab[i]..' not present in hashamp')
      end
   end
   return lookup
end

local function addDropout(gru, dropout)
   local bgru = nn.GRUST(gru.inputSize, gru.outputSize, false, dropout, true)
   bgru:migrate(gru:parameters())
   return bgru
end

--------------------------------------------
-- Skip Thoughts seq2vec models 

skipthoughts.createUniSkip = function(vocab, dirname, dropout, norm)

   local lookup = skipthoughts.createLookupTable(vocab, dirname, 'uni')
   local gru = torch.load(paths.concat(dirname, 'uni_gru.t7'))
   
   if dropout and dropout ~= 0 then
      gru = addDropout(gru, dropout)
   end
   gru:trimZero(1) -- doesn't forward padded zeros

   local seq_gru = nn.Sequencer(gru)

   local uni_skip = nn.Sequential()
   uni_skip:add(lookup)
   uni_skip:add(nn.SplitTable(2)) -- split on sequence dimension
   uni_skip:add(seq_gru)
   uni_skip:add(nn.SelectTable(-1))
   if norm then
      uni_skip:add(nn.Normalize(2))
   end

   return uni_skip
end


skipthoughts.createBiSkip = function(vocab, dirname, dropout, norm)
   local lookup = skipthoughts.createLookupTable(vocab, dirname, 'bi')
   local gru_fwd = torch.load(paths.concat(dirname, 'bi_gru_fwd.t7'))
   local gru_bwd = torch.load(paths.concat(dirname, 'bi_gru_bwd.t7'))
   
   if dropout and dropout ~= 0 then
      gru_fwd = addDropout(gru_fwd, dropout)
      gru_bwd = addDropout(gru_bwd, dropout)
   end
   gru_fwd:trimZero(1)
   gru_bwd:trimZero(1)

   -- local merge = nn.Sequential()
   --    :add(nn.ConcatTable()
   --       :add(nn.SelectTable(2))
   --       :add(nn.SelectTable(1)))
   --    :add(nn.JoinTable(1,1))

   local bi_skip = nn.Sequential()
   bi_skip:add(lookup)
   bi_skip:add(nn.SplitTable(2))
   --bi_skip:add(nn.BiSequencer(gru_bwd, gru_fwd, merge))
   bi_skip:add(nn.BiSequencer(gru_fwd, gru_bwd))
   -- bi_skip:add(
   --    nn.ConcatTable()
   --       :add(nn.Sequencer(gru_fwd))
   --       :add(
   --          nn.Sequential()
   --             :add(nn.ReverseTable())
   --             :add(nn.Sequencer(gru_bwd))
   --             :add(nn.ReverseTable())
   --       )

   -- )
   -- bi_skip:add(nn.ZipTable())
   -- bi_skip:add(nn.Sequencer(nn.JoinTable(1, 1)))

   bi_skip:add(nn.SelectTable(-1))
   if norm then
      bi_skip:add(nn.Normalize(2))
   end

   return bi_skip
end

skipthoughts.createCombineSkip = function(vocab, dirname, dropout, norm)
   local uni_skip = skipthoughts.createUniSkip(vocab, dirname, dropout, norm)
   local bi_skip  = skipthoughts.createBiSkip(vocab, dirname, dropout, norm)
   local comb_skip = nn.Sequential()
   comb_skip:add(
      nn.ConcatTable()
         :add(uni_skip)
         :add(bi_skip)
   )
   comb_skip:add(nn.JoinTable(1,1))

   return comb_skip
end

return skipthoughts
