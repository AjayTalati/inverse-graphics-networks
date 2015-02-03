
local ACR_helper = {}

require("sys")


function ACR_helper:gradHelper(mode, start_x, start_y, endhere_x, endhere_y, output, pose, bsize, template, gradOutput, _gradTemplate, _gradPose)
  -- print(gradOutput)
  if mode == "singlecore" then
    start_x = 1; start_y=1;
    endhere_x = output:size()[2]; endhere_y = output:size()[3]
    gradTemplate = _gradTemplate; gradPose = _gradPose
  else
    --need to add them outside the thread as threads may override these variables causing funny errors
    gradTemplate = torch.zeros(_gradTemplate:size()); gradPose = torch.zeros(_gradPose:size())
  end

  print(gradOutput)

  for output_x = start_x, endhere_x do
    for output_y = start_y, endhere_y do
      --sys.tic()
      -- calculate the correspondence between template and output
      output_coords = torch.Tensor({output_x, output_y, 1})
      --template_coords = pose * output_coords
      template_coords = torch.zeros(bsize, 3)
      for i=1, bsize do
        template_coords[{i, {}}] = pose[{bsize,{},{}}]*output_coords
      end

      template_x = template_coords[{{},1}] --template_coords[1]
      template_y = template_coords[{{},2}] --template_coords[2]

      template_x = template_x - 1/2 
      template_y = template_y - 1/2 

      local x_high_coeff = torch.Tensor(bsize)
      local y_high_coeff = torch.Tensor(bsize)

      --x_high_coeff:map(template_x, function(xhc, txx) return math.fmod(txx, 1) end) --x_high_coeff = template_x % 1
      --y_high_coeff:map(template_y, function(yhc, tyy) return math.fmod(tyy,1) end) --y_high_coeff = template_y % 1

      for i=1,bsize do
        x_high_coeff[i] = math.fmod(template_x[i],1)
        y_high_coeff[i] = math.fmod(template_y[i],1)
      end

      x_low_coeff  =  -x_high_coeff + 1
      y_low_coeff  =  -y_high_coeff + 1

      x_low  = torch.floor(template_x) 
      x_high = x_low + 1 
      y_low  = torch.floor(template_y) 
      y_high = y_low + 1 

      --[[   
      for ii=1,bsize do
        -----------------------------------------------------------------------------
        --------------------------- Template gradient -------------------------------
        -----------------------------------------------------------------------------
        -- calculate the derivatives for the template
        x_vec = torch.Tensor({x_low_coeff[ii], x_high_coeff[ii]})
        y_vec = torch.Tensor({y_low_coeff[ii], y_high_coeff[ii]})

        -- outer product
        dOutdPose = torch.ger(x_vec, y_vec)
        for i, x in ipairs({x_low[ii], x_high[ii]}) do
          for j, y in ipairs({y_low[ii], y_high[ii]}) do
              if x >= 1 and x <= template:size()[2]
                and y >= 1 and y <= template:size()[3] then
                gradTemplate[ii][x][y] = gradTemplate[ii][x][y] + dOutdPose[i][j] * gradOutput[ii][output_x][output_y] 
              end
          end
        end
      end
      --]]
      

      
      -- xt = a*x + b*y + c;
      -- yt = d*x + e*y + f;
      -- Ixy = (1./((x2-x1)*(y2-y1))) * ( (t11*(x2-xt)*(y2-yt)) + (t21*(xt-x1)*(y2-yt)) + (t12*(x2-xt)*(yt-y1)) + (t22*(xt-x1)*(yt-y1)) )
      xxx = nil; yyy=nil;
      for ii=1,bsize do
        local x_low_ii = x_low[ii]; local y_low_ii = y_low[ii];
        local x_high_ii = x_high[ii]; local y_high_ii = y_high[ii];
        local ratio_xy = (x_low_ii-x_high_ii)*(y_low_ii-y_high_ii)

        --print('before:', gradTemplate)
        --------------------------- Template gradient -------------------------------
        if x_low_ii >= 1 and x_low_ii <= template:size()[2] and y_low_ii >= 1 and y_low_ii <= template:size()[2] then
          gradTemplate[{ii, x_low_ii, y_low_ii}] = gradTemplate[{ii, x_low_ii, y_low_ii}] + ( (((template_x-x_high_ii)*(template_y-y_high_ii))/ ratio_xy ) * gradOutput[ii][output_x][output_y] ) 
          --print(x_low_ii, y_low_ii, template_x[1], template_y[1], gradOutput[ii][output_x][output_y])
          xxx = x_low_ii; yyy= y_low_ii
        end

        if x_low_ii >= 1 and x_low_ii <= template:size()[2] and y_high_ii >= 1 and y_high_ii <= template:size()[2] then
          gradTemplate[{ii, x_low_ii,y_high_ii}] = gradTemplate[{ii, x_low_ii,y_high_ii}] + ( -(((template_x-x_high_ii)*(template_y-y_low_ii))/ ratio_xy ) * gradOutput[ii][output_x][output_y] )
          --print(x_low_ii, y_high_ii, template_x[1], template_y[1], gradOutput[ii][output_x][output_y])
          xxx=x_low_ii; yyy = y_high_ii
        end

        if x_high_ii >= 1 and x_high_ii <= template:size()[2] and y_low_ii >= 1 and y_low_ii <= template:size()[2] then
          gradTemplate[{ii,x_high_ii,y_low_ii}] = gradTemplate[{ii,x_high_ii,y_low_ii}] + ( -(((template_x-x_low_ii)*(template_y-y_high_ii))/ ratio_xy ) * gradOutput[ii][output_x][output_y] )
          --print(x_high_ii, y_low_ii, template_x[1], template_y[1], gradOutput[ii][output_x][output_y])
          xxx=x_high_ii; yyy = y_low_ii
        end
      
        if x_high_ii >= 1 and x_high_ii <= template:size()[2] and y_high_ii >= 1 and y_high_ii <= template:size()[2] then
          gradTemplate[{ii,x_high_ii,y_high_ii}] = gradTemplate[{ii,x_high_ii,y_high_ii}] + ( (((template_x-x_low_ii)*(template_y-y_low_ii))/ ratio_xy ) * gradOutput[ii][output_x][output_y] )
          --print(x_high_ii, y_high_ii, template_x[1], template_y[1], gradOutput[ii][output_x][output_y])
          xxx = x_high_ii; yyy = y_high_ii
        end

        if xxx == 1 and yyy == 2  then
          print(output_x, output_y)
          print('template_coords' , template_coords)
          print('template_x', template_x) 
          print('template_y', template_y)
          print(x_low_ii, x_high_ii, y_low_ii, y_high_ii)
          print(gradTemplate[{ii,xxx,yyy}], gradOutput[{ii,output_x,output_y}])
          print('---\n')          
        end
      end
      --]]


      --print('template:', sys.toc())

      --sys.tic()

      --[[
        matlab:
        -- geoPose = ((a,b,c),
                      (d,e,f),
                      (g,h,i))
      --Ixy = [x_h - (a*x + b*y + c), (a*x + b*y + c) - x_l] * [T_ll, T_lh; T_hl, T_hh] * [y_h - (d*x + e*y + f); (d*x + e*y + f) - y_l]
      -- gradient(Ixy, [a b c d e f]) <- gets gradient of pose
      --[[a -> (T_hh*x - T_lh*x)*(f - y_l + d*x + e*y) - (T_hl*x - T_ll*x)*(f - y_h + d*x + e*y)
          b -> (T_hh*y - T_lh*y)*(f - y_l + d*x + e*y) - (T_hl*y - T_ll*y)*(f - y_h + d*x + e*y)
          c -> (T_hh - T_lh)*(f - y_l + d*x + e*y) - (T_hl - T_ll)*(f - y_h + d*x + e*y)
          d -> x*(T_hh*(c - x_l + a*x + b*y) - T_lh*(c - x_h + a*x + b*y)) - x*(T_hl*(c - x_l + a*x + b*y) - T_ll*(c - x_h + a*x + b*y))
          e -> y*(T_hh*(c - x_l + a*x + b*y) - T_lh*(c - x_h + a*x + b*y)) - y*(T_hl*(c - x_l + a*x + b*y) - T_ll*(c - x_h + a*x + b*y))
          f -> T_hh*(c - x_l + a*x + b*y) - T_lh*(c - x_h + a*x + b*y) - T_hl*(c - x_l + a*x + b*y) + T_ll*(c - x_h + a*x + b*y)
      --]]

      --[[
         gradient(Ixy, [T_ll T_lh T_hl T_hh]) <- gradient of template at locations ll, lh, hl, hh
      --]]

      template_val_xhigh_yhigh = ACR_helper:getTemplateValue(bsize, template, x_high, y_high)
      template_val_xhigh_ylow = ACR_helper:getTemplateValue(bsize, template, x_high, y_low)
      template_val_xlow_ylow = ACR_helper:getTemplateValue(bsize, template, x_low, y_low)
      template_val_xlow_yhigh = ACR_helper:getTemplateValue(bsize, template, x_low, y_high)

      pose_1_1 = pose[{{},1,1}]
      pose_1_2 = pose[{{},1,2}]
      pose_1_3 = pose[{{},1,3}]
      pose_2_1 = pose[{{},2,1}]
      pose_2_2 = pose[{{},2,2}]
      pose_2_3 = pose[{{},2,3}]


      cache1 = (pose_2_3 - y_low + pose_2_1*output_x + pose_2_2*output_y)
      cache2 = (pose_2_3 - y_high + pose_2_1*output_x + pose_2_2*output_y)
      cache3 = (pose_1_3 - x_low + pose_1_1*output_x + pose_1_2*output_y)
      cache4 = (pose_1_3 - x_high + pose_1_1*output_x + pose_1_2*output_y)

      cache5 = torch.cmul(template_val_xhigh_yhigh, cache3)
      cache6 = torch.cmul(template_val_xlow_yhigh, cache4)
      cache7 = torch.cmul(template_val_xhigh_ylow, cache3)
      cache8 = torch.cmul(template_val_xlow_ylow, cache4)

      cache9 = torch.cmul(gradOutput[{{},output_x,output_y}], cache5-cache6 )
      cache10 = (cache7-cache8)

      cache11 = torch.cmul(template_val_xhigh_ylow - template_val_xlow_ylow, cache2)

      cache12 = torch.cmul(
              gradOutput[{{},output_x,output_y}],
              torch.cmul(template_val_xhigh_yhigh - template_val_xlow_yhigh, cache1)
            )

      cache13 =  cache12 - cache11

      cache14 = (cache9 - cache10)


      -- add dCost/dOut(x,y) * dOut(x,y)/dPose for this (x,y)
      gradPose[{{},1,1}] = gradPose[{{},1,1}] + cache13*output_x

      gradPose[{{},1,2}] = gradPose[{{},1,2}] + cache13*output_y

      gradPose[{{},1,3}] = gradPose[{{},1,3}] + cache12 - cache11

      gradPose[{{},2,1}] = gradPose[{{},2,1}] +  cache14*output_x

      gradPose[{{},2,2}] = gradPose[{{},2,2}] + cache14*output_y

      gradPose[{{},2,3}] = gradPose[{{},2,3}] +
              torch.cmul(gradOutput[{{},output_x,output_y}], cache5) - cache6 - cache7 + cache8

      --print(output_x, output_y,gradPose[{{},2,3}][1] )
      --if output_x == 3 and output_y == 4 then
      --  print('CPU:',  template_val_xlow_ylow[1], template_val_xlow_yhigh[1], template_val_xhigh_ylow[1], template_val_xhigh_yhigh[1])
        --for i = 1, 3 do
        --  for j = 1, 3 do
        --    print(pose[1][i][j])
        --  end
        --end
      --end

      --print('posegrad:' , sys.toc())
    end
  end

  if tostring(torch.sum(gradPose)) == tostring(0/0) then
    print("ERROR!")
--    print('gradOutput:', torch.sum(gradOutput))
  end

  return gradTemplate, gradPose
    --]]
end


function ACR_helper:getTemplateValue(bsize, template, template_x, template_y)
  local template_x_size = template:size()[2] + 1
  local template_y_size = template:size()[3] + 1
  local output_x = torch.floor(template_x + template_x_size / 2)
  local output_y = torch.floor(template_y + template_y_size / 2)

  local res = torch.zeros(bsize)
  for i = 1,bsize do
    if output_x[i] < 1 or output_x[i] > template:size()[2] or output_y[i] < 1 or output_y[i] > template:size()[3] then
      res[i] = 0
    else
      res[i] = template[i][output_x[i]][output_y[i]]
    end
  end
  return res
end

function ACR_helper:getInterpolatedTemplateValue(bsize, template, template_x, template_y)
  template_x = template_x - 1/2
  template_y = template_y - 1/2

  local x_high_coeff = torch.Tensor(bsize)
  local y_high_coeff = torch.Tensor(bsize)

  --x_high_coeff:map(template_x, function(xhc, txx) return math.fmod(txx, 1) end) --x_high_coeff = template_x % 1
  --y_high_coeff:map(template_y, function(yhc, tyy) return math.fmod(tyy,1) end) --y_high_coeff = template_y % 1

  for i=1,bsize do
    x_high_coeff[i] = math.fmod(template_x[i],1)
    y_high_coeff[i] = math.fmod(template_y[i],1)
  end

  x_low_coeff  =  -x_high_coeff + 1
  y_low_coeff  =  -y_high_coeff + 1

  x_low  = torch.floor(template_x)
  x_high = x_low + 1
  y_low  = torch.floor(template_y)
  y_high = y_low + 1


  return torch.cmul(ACR_helper:getTemplateValue(bsize, template, x_low,  y_low) , torch.cmul(x_low_coeff  , y_low_coeff))  +
         torch.cmul(ACR_helper:getTemplateValue(bsize, template, x_high, y_low) , torch.cmul(x_high_coeff , y_low_coeff )) +
         torch.cmul(ACR_helper:getTemplateValue(bsize, template, x_low,  y_high), torch.cmul(x_low_coeff  , y_high_coeff ))+
         torch.cmul(ACR_helper:getTemplateValue(bsize, template, x_high, y_high), torch.cmul(x_high_coeff , y_high_coeff ))

  --[[
  local x2_x1 = x_high - x_low
  local y2_y1 = y_high - y_low 
  local x2_x = x_high - template_x
  local y2_y = y_high - template_y
  local x_x1 = template_x - x_low
  local y_y1 = template_y - y_low


  local t11 = ACR_helper:getTemplateValue(bsize, template, x_low, y_low)
  local t12 = ACR_helper:getTemplateValue(bsize, template, x_low, y_high)
  local t21 = ACR_helper:getTemplateValue(bsize, template, x_high, y_low)
  local t22 = ACR_helper:getTemplateValue(bsize, template, x_high, y_high)

  local ratio = torch.pow(torch.cmul(x2_x1, y2_y1),-1)

  local term_t11 = torch.cmul(t11, torch.cmul(x2_x, y2_y))
  local term_t21 = torch.cmul(t21, torch.cmul(x_x1, y2_y))
  local term_t12 = torch.cmul(t12, torch.cmul(x2_x, y_y1))
  local term_t22 = torch.cmul(t22, torch.cmul(x_x1, y_y1))

  return torch.cmul(ratio, (term_t11 + term_t12 + term_t21 + term_t22))
  --]]
end




return ACR_helper