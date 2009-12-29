#!/usr/bin/ruby
# jvm-gc-stats: gather stats from jvm garbage collection trace and publish ganglia graphs

$debug = true
$tailSleepSec = 1
$tailBlockSize = 2048

def tail(file)
   f = File.new(file, "r")
   f.seek(0, IO::SEEK_END)

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

$minor = Regexp.new('ParNew: (\d+)K->(\d+).*?user=(\d+.\d+).*?real=(\d+.\d+)')
$fail = Regexp.new('fail')
$cmsStart = Regexp.new('\[CMS-concurrent.*start\]')
$cmsConcurrent = Regexp.new('CMS-concurrent.*?user=(\d+.\d+).*?real=(\d+.\d+)')
$cmsBlock = Regexp.new('CMS-(initial-|re)mark.*?user=(\d+.\d+).*?real=(\d+.\d+)')
$startup = Regexp.new('^Heap$|^ par new generation|^  eden space|^  from space|^  to   space|^ concurrent mark-sweep generation|^ concurrent-mark-sweep perm')

def ingest(str)
  case str
  when $minor
    fromK = $~[1].to_i
    toK = $~[2].to_i
    deltaK = fromK - toK
    ratio = toK.to_f / fromK.to_f
    userSec = $~[3].to_f
    realSec = $~[4].to_f
    kPerRealSec = deltaK / realSec
    kPerUserSec = deltaK / userSec
    if $debug then
      printf("minor ratio %4f kPerUserSec %8d kPerRealSec %8d user %5f real %5f\n",
             ratio, kPerUserSec, kPerRealSec, userSec, realSec)
    end
    report("minor.survivalRatio", ratio)
    report("minor.kbytesPerSec", kPerRealSec)
    report("minor.userSec", userSec)
    report("minor.realSec", realSec)
  when $fail
    puts "FAIL #{str}" if $debug
    report("fail", 1)
  when $cmsStart
    puts "ignore cms start #{str}" if $debug
  when $cmsConcurrent
    userSec = $~[1].to_f
    realSec = $~[2].to_f
    printf "major concurrent user %5f real %5f %s\n", userSec, realSec, str if $debug
    report("major.concur.userSec", userSec)
    report("major.concur.realSec", realSec)
  when $cmsBlock
    userSec = $~[2].to_f
    realSec = $~[3].to_f
    printf "major block user %5f real %5f %s\n", userSec, realSec, str if $debug
    report("major.block.userSec", userSec)
    report("major.block.realSec", realSec)
  when $startup
    puts "ignore startup #{str}" if $debug
  else
    puts "UNMATCHED #{str}"
  end
end

def report(key, value)
  exec = "gmetric -tfloat -njvm.gc.#{key} -v#{value}"
  system(exec)
end

if (ARGV[0]) then
  filename = ARGV[0]
else
  filename = "stdout"
end

tail(filename)
