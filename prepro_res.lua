------------------------------------------------------------------------------
--  Multimodal Residual Networks for Visual QA
--  Jin-Hwa Kim, Sang-Woo Lee, Dong-Hyun Kwak, Min-Oh Heo, 
--    Jeonghee Kim, Jung-Woo Ha, Byoung-Tak Zhang 
--  https://arxiv.org/abs/1606.01455
--
--  This code is based on 
--    https://github.com/VT-vision-lab/VQA_LSTM_CNN/blob/master/prepro_img.lua
-----------------------------------------------------------------------------

require 'nn'
require 'optim'
require 'torch'
require 'nn'
require 'math'
require 'cunn'
require 'cudnn'
require 'cutorch'
require 'image'
require 'hdf5'
cjson=require('cjson') 
require 'xlua'
local t = require '../fb.resnet.torch/datasets/transforms'

-------------------------------------------------------------------------------
-- Input arguments and options
-------------------------------------------------------------------------------
cmd = torch.CmdLine()
cmd:text()
cmd:text('Options')
cmd:option('-input_json','data_train-val_test-dev_2k/data_prepro.json','path to the json file containing vocab and answers')
cmd:option('-image_root','','path to the image root')
cmd:option('-cnn_model', '', 'path to the cnn model')
cmd:option('-batch_size', 10, 'batch_size')

cmd:option('-out_name', 'data_train-val_test-dev_2k/data_res.h5', 'output name')
cmd:option('-gpuid', 1, 'which gpu to use. -1 = use CPU')
cmd:option('-backend', 'cudnn', 'nn|cudnn')

opt = cmd:parse(arg)
print(opt)

cutorch.setDevice(opt.gpuid)
net=torch.load(opt.cnn_model);

-- Remove the fully connected layer
assert(torch.type(net:get(#net.modules)) == 'nn.Linear')
net:remove(#net.modules)

print(net)
net:evaluate()

-- The model was trained with this input normalization
local meanstd = {
   mean = { 0.485, 0.456, 0.406 },
   std = { 0.229, 0.224, 0.225 },
}

print('=== Full Crop Version ===')  -- according to Lee's hunch
local transform = t.Compose{
   --t.Scale(256),
   t.Scale(224),
   t.ColorNormalize(meanstd),
   t.CenterCrop(224)
}

imloader={}
function imloader:load(fname)
    self.im="rip"
    if not pcall(function () self.im=image.load(fname); end) then
        if not pcall(function () self.im=image.loadPNG(fname); end) then
            if not pcall(function () self.im=image.loadJPG(fname); end) then
            end
        end
    end
end
function loadim(imname)
    imloader:load(imname)
    im=imloader.im
    if im:size(1)==1 then
        im2=torch.cat(im,im,1)
        im2=torch.cat(im2,im,1)
        im=im2
    elseif im:size(1)==4 then
        im=im[{{1,3},{},{}}]
    end
    -- Scale, normalize, and crop the image
    im = transform(im)
    -- View as mini-batch of size 1
    im = im:view(1, table.unpack(im:size():totable()))
    return im
end

local image_root = opt.image_root
-- open the mdf5 file

local file = io.open(opt.input_json, 'r')
local text = file:read()
file:close()
json_file = cjson.decode(text)

local train_list={}
for i,imname in pairs(json_file['unique_img_train']) do
    table.insert(train_list, image_root .. imname)
end

local test_list={}
for i,imname in pairs(json_file['unique_img_test']) do
    table.insert(test_list, image_root .. imname)
end

local ndims=2048
local batch_size = opt.batch_size
local sz=#train_list
local feat_train=torch.CudaTensor(sz,ndims)
print(string.format('processing %d images...',sz))
for i=1,sz,batch_size do
    xlua.progress(i, sz)
    r=math.min(sz,i+batch_size-1)
    ims=torch.CudaTensor(r-i+1,3,224,224)
    for j=1,r-i+1 do
        ims[j]=loadim(train_list[i+j-1]):cuda()
    end
    net:forward(ims)
    feat_train[{{i,r},{}}]=net.output:clone()
    collectgarbage()
end

print('DataLoader loading h5 file: ', 'data_train')
local sz=#test_list
local feat_test=torch.CudaTensor(sz,ndims)
print(string.format('processing %d images...',sz))
for i=1,sz,batch_size do
    xlua.progress(i, sz)    
    r=math.min(sz,i+batch_size-1)
    ims=torch.CudaTensor(r-i+1,3,224,224)
    for j=1,r-i+1 do
        ims[j]=loadim(test_list[i+j-1]):cuda()
    end
    net:forward(ims)
    feat_test[{{i,r},{}}]=net.output:clone()
    collectgarbage()
end

local train_h5_file = hdf5.open(opt.out_name, 'w')
train_h5_file:write('/images_train', feat_train:float())
train_h5_file:write('/images_test', feat_test:float())
train_h5_file:close()

