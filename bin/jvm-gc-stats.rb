#!/usr/bin/ruby
# jvm-gc-stats: gather stats from jvm garbage collection trace and publish ganglia graphs

$debug = true
$report = false
$tailOnly = false
$tailSleepSec = 1
$tailBlockSize = 2048

def tail(file)
  f = File.new(file, "r")
  f.seek(0, IO::SEEK_END) if $tailOnly

  lines = ""
  loop do
    begin
      # Limit reads to prevent loading entire file into memory if not seeking to end
      begin
        part = f.read_nonblock($tailBlockSize)
      rescue
        part = nil
      end

      if part == nil then
        # End of file reached, wait for more data
        sleep $tailSleepSec
      else
        lines += part
      end
    end until lines["\n"]

    # If there isn't a null trailing field, last string isn't newline terminated
    split = lines.split("\n", $tailBlockSize)
    if split[-1] == "" then
      # Remove null trailing field
      split.pop
      lines = ""
    else
      # Save partial line for next round
      lines = split.pop
    end
    split.each { |line|
      ingest(line)
    }
  end
end

$userReal = '.*?user=(\d+.\d+).*?real=(\d+.\d+)'
$minor = Regexp.new('ParNew: (\d+)K->(\d+)' + $userReal)
$full = Regexp.new('Full GC \[CMS: (\d+)K->(\d+)' + $userReal)
$promotionFailed = Regexp.new('promotion failed' + $userReal)
$scavange = Regexp.new('Trying a full collection because scavenge failed')
$cmsStart = Regexp.new('\[CMS-concurrent.*start\]')
$cmsConcurrent = Regexp.new('CMS-concurrent' + $userReal)
$cmsBlock = Regexp.new('CMS-(initial-|re)mark' + $userReal)
$startup = Regexp.new('^Heap$|^ par new generation|^  eden space|^  from space|^  to   space|^ concurrent mark-sweep generation|^ concurrent-mark-sweep perm')

def denominator(string)
  rv = string.to_f
  # Assume that collections under a millisecond took half a millisecond
  rv = 0.05 if rv == 0
  rv
end

def minorAndFull(match, collection, str)
  fromK = match[1].to_i
  toK = match[2].to_i
  deltaK = fromK - toK
  ratio = toK.to_f / fromK.to_f
  userSec = denominator(match[3])
  realSec = denominator(match[4])
  kPerRealSec = deltaK / realSec
  kPerUserSec = deltaK / userSec

  if $debug then
    printf("%-15s user %5.2f real %5.2f ratio %1.3f kPerUserSec %10d kPerRealSec %10d \n",
           collection, userSec, realSec, ratio, kPerUserSec, kPerRealSec)
  end

  report("#{collection}.survivalRatio", ratio)
  report("#{collection}.kbytesPerSec", kPerRealSec)
  report("#{collection}.userSec", userSec)
  report("#{collection}.realSec", realSec)
end

def ingest(str)
  case str
  when $minor
    minorAndFull($~, "minor", str)
  when $full
    minorAndFull($~, "full", str)
  when $promotionFailed
    userSec = $~[1].to_f
    realSec = $~[2].to_f
    printf "%-15s user %5.2f real %5.2f\n", "promoFail", userSec, realSec if $debug
    # Reporting userSec for promotion failures is redundant
    report("promoFail.realSec", realSec)
  when $cmsConcurrent
    userSec = $~[1].to_f
    realSec = $~[2].to_f
    printf "%-15s user %5.2f real %5.2f\n", "major concur", userSec, realSec if $debug
    report("major.concur.userSec", userSec)
    report("major.concur.realSec", realSec)
  when $cmsBlock
    userSec = $~[2].to_f
    realSec = $~[3].to_f
    printf "%-15s user %5.2f real %5.2f\n", "major block", userSec, realSec if $debug
    report("major.block.userSec", userSec)
    report("major.block.realSec", realSec)
  when $cmsStart
    puts "ignore cms start #{str}" if $debug
  when $startup
    puts "ignore startup #{str}" if $debug
  when $scavange
    puts "ignore scavange #{str}" if $debug
  else
    puts "UNMATCHED #{str}"
  end
end

def report(key, value)
  if $report then
    exec = "gmetric -tfloat -njvm.gc.#{key} -v#{value}"
    system(exec)
  end
end

if (ARGV[0]) then
  filename = ARGV[0]
else
  filename = "stdout"
end

tail(filename)
