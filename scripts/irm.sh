#!/usr/bin/env bash

read -ra input <<< "$(cast abi-decode "_()(uint256,uint256,uint256,uint256,int256,uint256,uint256)" "$1" | sed 's/ .*//' | xargs)"

rate=$(bc -l <<< "
  scale = 2 * 18

  wad       = 1000000000000000000
  assets    = ${input[0]} / wad
  debt      = ${input[1]} / wad
  backup    = ${input[2]} / wad
  a         = ${input[3]} / wad
  b         = ${input[4]} / wad
  umax      = ${input[5]} / wad
  unat      = ${input[6]} / wad 
  uf        = 1 - unat / 2
  uLiq0     = l(unat / (1 - unat))
  ss        = 1

  liquidity = assets - debt - backup
  
  if (assets > 0) utilization = debt / assets else utilization = 0

  r = a / (umax - utilization) + b

  if (liquidity == 0) rate = r
  else {
    uliq = 1 - liquidity / assets
    if (utilization > uliq)  rate = 0
    else if (uliq == 0) rate = r
    else rate = uf * r / (1 - (1 / (1 + e(-ss * (l(uliq / (1 - uliq)) - uLiq0)))) * uliq)
  }

  scale = 0
  print rate * wad / 1
")

cast --to-int256 -- "$rate" | tr -d '\n'
