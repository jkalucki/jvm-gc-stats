#!/usr/bin/ruby
# jvm-gc-stats: gather stats from jvm garbage collection trace and publish ganglia graphs

DEBUG           = true
REPORT          = false
TAIL_ONLY       = false
TAIL_SLEEP_SEC  = 1
TAIL_BLOCK_SIZE = 2048
ALL_MEASUREMENTS = %w[promoFail.realSec major.concur.userSec major.concur.realSec major.block.userSec] +
                   %w[%s.survivalRatio %s.kbytesPerSec %s.userSec %s.realSec].collect{|m| %w[minor full].collect{|s| m % s}}.flatten

def open_file(file)
  f = File.new(file, "r")
end

def tail(file)
  f = open_file(file)
  f.seek(0, IO::SEEK_END) if TAIL_ONLY
  current_inode = f.stat.ino
  lines = ""
  loop do
    begin
      # Limit reads to prevent loading entire file into memory if not seeking to end
      part = f.read_nonblock(TAIL_BLOCK_SIZE) rescue nil

      if part == nil
        # End of file reached, wait for more data
        ALL_MEASUREMENTS.each{|m| report(m, 0)}
        sleep TAIL_SLEEP_SEC
        f = open(file) unless File.stat(file).ino == current_inode
        current_inode = f.stat.ino
      else
        lines += part
      end
    end until lines.include?("\n")

    # If there isn't a null trailing field, last string isn't newline terminated
    split = lines.split("\n", TAIL_BLOCK_SIZE)
    if split[-1] == ""
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

USER_REAL         = '.*?user=(\d+.\d+).*?real=(\d+.\d+)'
MINOR            = Regexp.new('ParNew: (\d+)K->(\d+)' + USER_REAL)
FULL             = Regexp.new('Full GC \[CMS: (\d+)K->(\d+)' + USER_REAL)
PROMOTION_FAILED = Regexp.new('promotion failed' + USER_REAL)
SCAVANGE         = Regexp.new('Trying a full collection because scavenge failed')
CMS_START        = Regexp.new('\[CMS-concurrent.*start\]')
CMS_CONCURRENT   = Regexp.new('CMS-concurrent' + USER_REAL)
CMS_BLOCK        = Regexp.new('CMS-(initial-|re)mark' + USER_REAL)
STARTUP          = Regexp.new('^Heap$|^ par new generation|^  eden space|^  from space|^  to   space|^ concurrent mark-sweep generation|^ concurrent-mark-sweep perm')

def denominator(string)
  rv = string.to_f
  # Assume that collections under a millisecond took half a millisecond
  rv = 0.05 if rv == 0
  rv
end

def minorAndFull(match, collection, str)
  fromK       = match[1].to_i
  toK         = match[2].to_i
  deltaK      = fromK - toK
  ratio       = toK.to_f / fromK.to_f
  userSec     = denominator(match[3])
  realSec     = denominator(match[4])
  kPerRealSec = deltaK / realSec
  kPerUserSec = deltaK / userSec

  if DEBUG
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
  when MINOR
    minorAndFull($~, "minor", str)
  when FULL
    minorAndFull($~, "full", str)
  when PROMOTION_FAILED
    userSec = $~[1].to_f
    realSec = $~[2].to_f
    printf "%-15s user %5.2f real %5.2f\n", "promoFail", userSec, realSec if DEBUG
    # Reporting userSec for promotion failures is redundant
    report("promoFail.realSec", realSec)
  when CMS_CONCURRENT
    userSec = $~[1].to_f
    realSec = $~[2].to_f
    printf "%-15s user %5.2f real %5.2f\n", "major concur", userSec, realSec if DEBUG
    report("major.concur.userSec", userSec)
    report("major.concur.realSec", realSec)
  when CMS_BLOCK
    userSec = $~[2].to_f
    realSec = $~[3].to_f
    printf "%-15s user %5.2f real %5.2f\n", "major block", userSec, realSec if DEBUG
    report("major.block.userSec", userSec)
    report("major.block.realSec", realSec)
  when CMS_START
    puts "ignore cms start #{str}" if DEBUG
  when STARTUP
    puts "ignore startup #{str}" if DEBUG
  when SCAVANGE
    puts "ignore scavange #{str}" if DEBUG
  else
    puts "UNMATCHED #{str}"
  end
end

def report(key, value)
  if REPORT
    exec = "gmetric -tfloat -njvm.gc.#{key} -v#{value}"
    system(exec)
  end
end

if (ARGV[0])
  filename = ARGV[0]
else
  filename = "stdout"
end

tail(filename)
