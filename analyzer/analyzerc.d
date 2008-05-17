module analyzerc;

import std.stdio;
import std.string;
import std.conv;
import std.file;
import std.path;
import std.date : d_time;
import std.c.time;
import logreader;
import mapfile;
import analysis;

string[PACKET_MAX] eventNames = ["PACKET_MALLOC", "PACKET_CALLOC", "PACKET_REALLOC", "PACKET_EXTEND", "PACKET_FREE", "PACKET_MEMORY_DUMP", "PACKET_MEMORY_MAP", "PACKET_TEXT"];
char  [PACKET_MAX] eventChars = "mcrxfDMt";

char  [B_MAX] pageChars = "45678901P+.x";

int main(string[] argv)
{
	writefln("Diamond Memory Log Analyzer, v0.1");
	writefln("by Vladimir \"CyberShadow\" Panteleev, 2008");
	writefln();
	
	void progressCallback(ulong pos, ulong max)
	{
		writef("%d%%\r", pos*100/max);
		fflush(stdout);
	}
	
	string fileName;
	string mapFileName;
	foreach(arg;argv[1..$])
		if(getExt(arg)=="mem")
			fileName = arg;
		else	
		if(getExt(arg)=="map")
			mapFileName = arg;
		else
			writefln("Don't know what to do with .%s files.", getExt(arg));
	
	if(fileName is null)
	{
		fileName = findMostRecent("*.mem");
		if(fileName is null)
		{
			writefln("There are no .mem files in the current directory. Specify a memory log file on the command line, or run without parameters to use the most recent file in the current directory.");
			return 1;
		}
		writefln("Using the most recent memory dump file.");
	}
	writefln("Loading %s...", fileName);
	auto log = new LogReader(fileName);
	try
		log.load(&progressCallback);
	catch(Exception e)
		writefln("Error: %s", e.msg);
	if(log.events.length is 0)
		return 1;
	writefln("%d events loaded.", log.events.length);
	
	if(mapFileName is null)
	{
		mapFileName = findMostRecent("*.map");
		if(mapFileName is null)
			writefln("There are no .map files in the current directory and you have not specified one on the command line. Symbols will not be available.");
		else
			writefln("Using the most recent map file.");
	}
	MapFile map;
	if(mapFileName)
	{
		map = new MapFile(mapFileName);
		writefln("%d symbols loaded from %s.", map.symbols.length, mapFileName);
	}

	auto analysis = new Analysis(log);

	string mapLookUp(uint addr)
	{
		if(map is null)
			return "<no symbols>";
		else
			return map.lookup(addr);
	}
	
	void showEvent(int i)
	{
		auto event = log.events[i];
		writef("%7d @ %s: %-11s", i, timeStr(event.time), eventNames[event.type][7..$]);
		if(cast(MemoryAllocationEvent)event) with(cast(MemoryAllocationEvent)event)
			writefln(" %08X - %08X (%d bytes)", p, p+size, size);
		else
		if(cast(FreeEvent)event) with(cast(FreeEvent)event)
			writefln(" %08X", p);
		else
		if(cast(MemoryStateEvent)event) with(cast(MemoryStateEvent)event)
			writefln(" (%6d/%6d/%6d)", allocated, committed, total);
		else
		if(cast(TextEvent)event) with(cast(TextEvent)event)
			writefln(" - \"%s\"", text);
		else
			writefln();
	}

	void showInfo(MemoryStateEvent event, uint p, Pool* pool=null, uint value=0)
	{
		if(pool is null)
			foreach(ref epool;event.pools)
				if(p >= epool.addr && p < epool.topAddr)
					{ pool = &epool; break; }
		if(pool is null)
			throw new Exception("Specified address does not belong in any pool.");
		writef("%08X", p);
		if(value)
			writef(" -> %08X", value);
		uint pageNr = (p-pool.addr)/PAGESIZE;
		assert(pageNr < pool.npages);
		auto bin = pool.pagetable[pageNr];
		writef(" - %s", pageNames[bin]);
		Node* n = analysis.findNode(p);
		int biti = -1;
		if(n)
		{
			writef(", event #%d (%08X - %08X)", n.eventID, n.p, n.p+analysis.getNodeSize(n));
			biti = (n.p-pool.addr)/16;
		}
		else
		{
			writef(", not allocated");
			if(bin == B_PAGEPLUS)
			{
				while(pool.pagetable[pageNr]==B_PAGEPLUS)
					pageNr--;
				biti = pageNr*PAGESIZE/16;
			}
			else
			if(bin <= B_PAGE)
			{
				uint startAddr = p & ~(pageSizes[bin]-1);
				biti = (startAddr-pool.addr)/16;
			}
		}
		if(biti>=0)
		{
			if(Pool.readBit(pool.noscan, biti))
				writef(", NOSCAN");
			if(pool.finals.length && Pool.readBit(pool.finals, biti))
				writef(", FINALS");
			if(Pool.readBit(pool.freebits, biti))
				writef(", FREE");
		}
		writefln();
	}

	while(true)
	{
		if(analysis.cursor<0)
			writef("    \r> ");
		else
			writef("    \r%s%d> ", eventChars[log.events[analysis.cursor].type], analysis.cursor);
		auto args = split(strip(readln()), " ");
		if(args.length==0) continue;

		bool allRoots;
		
		try
			switch(tolower(args[0]))
			{
				case "stats":
				{
					int[PACKET_MAX] counts;
					foreach(event;log.events)
						counts[event.type]++;
					for(int i=0;i<PACKET_MAX;i++)
						writefln("%-20s: %8d", eventNames[i], counts[i]);
					writefln("%-20s: %8d", "Total", log.events.length);
					break;
				}
				case "allocstats":
				{
					static ulong[uint[]] stacks;
					foreach(event;log.events)
					{
						auto allocEvent = cast(LogReader.MemoryAllocationEvent)event;
						if(allocEvent is null) 
							continue;
						if(allocEvent.stackTrace in stacks)
							stacks[allocEvent.stackTrace] += allocEvent.size;
						else
							stacks[allocEvent.stackTrace] = allocEvent.size;
					}
					struct Sorter
					{
						uint[] stack;
					
						int opCmp(Sorter* s) 
						{
							ulong my = stacks[stack];
							ulong that = stacks[s.stack];
							return my==that?0:my>that?-1:1;
						}
					}
					Sorter[] sortedStacks = cast(Sorter[])stacks.keys;
					sortedStacks.sort;
					int n = 5;
					if(args.length>1)
						n = toInt(args[1]);
					if(n>sortedStacks.length) 
						n = sortedStacks.length;
					writefln("Top %d allocators by total allocated data:", n);
					foreach(sorter;sortedStacks[0..n])
					{
						writefln("=== %d ===", stacks[sorter.stack]);
						foreach(func;sorter.stack)
							writefln(" %08X  %s", func, mapLookUp(func));
					}
					break;
				}
				case "dumps":
				case "mdumps":
				case "memdumps":
				case "listdumps":
					foreach(i,event;log.events)
						if(event.type == PACKET_MEMORY_DUMP)
							showEvent(i);
					break;
				case "maps":
				case "mmaps":
				case "memmaps":
				case "listmaps":
					foreach(i,event;log.events)
						if(event.type == PACKET_MEMORY_MAP)
							showEvent(i);
					break;
				case "show":
				case "event":
				case "events":
				{
					int min, max;
					if(args.length==1)
						min = max = analysis.cursor;
					else
					if(args.length==2)
						min = max = toInt(args[1]);
					else
						min = toInt(args[1]), max = toInt(args[2]);
					if(min<0 || max>log.events.length-1 || min>max)
						throw new Exception("Invalid range");
					for(int i=min;i<=max;i++)
						showEvent(i);
					break;
				}
				case "stack":
				{
					int event;
					if(args.length==1)
						event = analysis.cursor;
					else
						event = toInt(args[1]);
					foreach(func;log.events[event].stackTrace)
						writefln(" %08X  %s", func, mapLookUp(func));
					break;
				}
				case "node":
				case "nodes":
				{
					if(analysis.cursor<0)
						throw new Exception("No data (use 'goto' to seek to an event)");
					uint min, max;
					if(args.length==1)
						throw new Exception("Specify a memory address or range");
					else
					if(args.length==2)
						min = max = fromHex(args[1]);
					else
						min = fromHex(args[1]), max = fromHex(args[2]);

					auto n = analysis.findNode(min, true);
					//auto event = cast(MemoryAllocationEvent)log.events[n.eventID];
					if(n is null) throw new Exception("Out of range");
					//writefln("findNode returned: p=%08X, next.p=%08X", n.p, n.next.p);
					for(;n && n.p+analysis.getNodeSize(n)<=min;n=n.next) {}
					for(; n && n.p <= max; n=n.next)
						showEvent(n.eventID);
					break;
				}
				case "search":
				{
					uint min, max;
					if(args.length==1)
						throw new Exception("Specify a memory address or range");
					else
					if(args.length==2)
						min = max = fromHex(args[1]);
					else
						min = fromHex(args[1]), max = fromHex(args[2]);
					foreach(i,event;log.events)
					{
						uint p1, p2;
						if(cast(MemoryAllocationEvent)event) with(cast(MemoryAllocationEvent)event)
							p1 = p, p2 = p + size;
						else
						if(cast(FreeEvent)event) with(cast(FreeEvent)event)
							p1 = p, p2 = p;
						else
							continue;
						if((p2 >= min) && (p1 <= max))
							showEvent(i);
					}
					break;
				}
				case "goto":
				{
					if(args.length!=2 || args[1].length==0)
						throw new Exception("Specify an event number or $ for the end of file.");
					int position;
					if(args[1]=="$" || args[1]=="end")
						position = log.events.length-1;
					else
					if(args[1][0]=='+')
						position = analysis.cursor+toInt(args[1][1..$]);
					else
					if(args[1][0]=='-')
						position = analysis.cursor-toInt(args[1][1..$]);
					else
						position = toInt(args[1]);
					analysis.goTo(position, &progressCallback);
					break;
				}
				case "pools":
				{
					int eventID;
					if(args.length==1)
						eventID = analysis.cursor;
					else
						eventID = toInt(args[1]);
					auto event = cast(MemoryStateEvent)log.events[eventID];
					if(event is null) throw new Exception("This is not a memory dump/map event.");
					foreach(ref pool;event.pools)
						writefln("%08X - %08X, %4d/%4d/%4d pages", pool.addr, pool.topAddr, pool.npages-pool.nfree, pool.ncommitted, pool.npages);
					break;
				}
				case "pages":
				case "map":
				{
					int eventID = analysis.cursor;
					uint address;
					if(args.length==1)
						address = 0;
					else
					{
						if(args.length==2)
							eventID = analysis.cursor;
						else
							eventID = toInt(args[2]);
						if(args[$-1]=="*")
							address = 0;
						else
							address = fromHex(args[$-1]);
					}
					if(eventID<0)
						throw new Exception("No data (specify or goto event)");
					auto event = cast(MemoryStateEvent)log.events[eventID];
					if(event is null) throw new Exception("This is not a memory dump/map event.");
					bool found;
					foreach(ref pool;event.pools)
						if(address==0 || (address >= pool.addr && address < pool.topAddr))
						{
							writefln("Page map for pool %08X - %08X (%4d/%4d/%4d pages):", pool.addr, pool.topAddr, pool.npages-pool.nfree, pool.ncommitted, pool.npages);
							writef("(page size = 0x1000)            +10000           +20000           +30000    ");
							foreach(pageNr,bin;pool.pagetable)
							{
								auto addr = pool.addr + pageNr*PAGESIZE;
								if(pageNr%64==0)
								{
									writefln;
									writef("%08X: ", addr);
								}
								else
								if(pageNr%16==0)
									writef(' ');
								bool hasScan, hasNoScan;
								// does this page have pointers?
								if(bin<=B_PAGEPLUS)
								{
									uint start, step;
									if(bin==B_PAGEPLUS)
									{
										start = pageNr;
										while(pool.pagetable[start]==B_PAGEPLUS)
											start--;
										start = start*PAGESIZE/16;
										step = PAGESIZE/16;
									}
									else
									{
										start = pageNr*PAGESIZE/16;
										step = pageSizes[bin]/16;
									}
									for(uint biti=start;biti<start+PAGESIZE/16;biti+=step)
										if(Pool.readBit(pool.noscan, biti))
											hasNoScan = true;
										else
											hasScan = true;
								}
								else
									hasNoScan = true;
								if(hasScan && !hasNoScan)
									highVideo();
								else
								if(!hasScan && hasNoScan)
									lowVideo();
								writef(pageChars[bin]);
								if(hasScan != hasNoScan)
									normVideo();
							}
							writefln();
							found = true;
						}
					if(!found)
						throw new Exception("Specified address does not belong in any pool.");
					break;
				}
				case "info":
				{
					if(analysis.cursor<0)
						throw new Exception("No data (use 'goto' to seek to an event)");
					if(args.length==1)
						throw new Exception("Specify an address");
					uint address = fromHex(args[1]);
					auto event = cast(MemoryStateEvent)log.events[analysis.cursor];
					if(event is null) throw new Exception("This is not a memory dump/map event.");
					showInfo(event, address);
					break;
				}
				case "allrefs":
				case "allroots":
					allRoots = true;
					goto Lroots;
				case "refs":
				case "roots":
					allRoots = false;
					goto Lroots;
				Lroots:
				{
					if(analysis.cursor<0)
						throw new Exception("No data (use 'goto' to seek to an event)");
					uint min, max;
					if(args.length==1)
						throw new Exception("Specify a memory address or range");
					else
					if(args.length==2)
						min = max = fromHex(args[1]);
					else
						min = fromHex(args[1]), max = fromHex(args[2]);
					auto event = cast(MemoryStateEvent)log.events[analysis.cursor];
					if(event is null) throw new Exception("This is not a memory dump/map event.");
					auto dataEvent = cast(MemoryDumpEvent)log.events[analysis.cursor];
					if(dataEvent is null && analysis.cursor>0) dataEvent = cast(MemoryDumpEvent)log.events[analysis.cursor-1];
					if(dataEvent is null) throw new Exception("This is not a memory dump event, or not directly following one.");
					int lastEvent, count;
					foreach(int poolNr,ref pool;event.pools)
					{
						uint[] data = cast(uint[])dataEvent.loadPoolData(poolNr);
						foreach(i,v;data)
							if(min <= v && v <= max)
							{
								uint address = pool.addr + i*uint.sizeof;
								if(!allRoots) // check if the reference is from something the GC would scan, unless the user wants to see all references
								{
									uint pageNr = (address-pool.addr)/PAGESIZE;
									assert(pageNr < pool.npages);
									auto bin = pool.pagetable[pageNr];
									if(bin >= B_FREE)
										continue;
									uint biti;
									if(bin == B_PAGEPLUS)
									{
										while(pool.pagetable[pageNr]==B_PAGEPLUS)
											pageNr--;
										biti = pageNr*PAGESIZE/16;
									}
									else
									{
										uint startAddr = address & ~(pageSizes[bin]-1);
										biti = (startAddr-pool.addr)/16;
									}
									//writefln("address=%08X, page=%s, startAddr => %08X", address, pageNames[bin], startAddr);
									if(Pool.readBit(pool.noscan, biti))
										continue;
								}

								Node* n = analysis.findNode(address);
								auto eventID = n is null ? 0 : n.eventID;
								if(eventID != lastEvent)
								{
									if(lastEvent && count>10)
										writefln("... and %d more from event #%d", count-10, lastEvent);
									count = 0;
									lastEvent = eventID;
								}
								count++;
								if(eventID==0 || count<=10)
									showInfo(event, address, &pool, v);
							}
					}
					if(lastEvent && count>10)
						writefln("... and %d more from event #%d", count-10, lastEvent);
					break;
				}
				case "dump":
				case "mdump":
				case "mem":
				case "memory":
				case "memdump":
				case "dumpmem":
				{
					if(analysis.cursor<0)
						throw new Exception("No data (use 'goto' to seek to an event)");
					uint min, max;
					if(args.length==1)
						throw new Exception("Specify a memory address or range");
					else
					if(args.length==2)
					{
						min = fromHex(args[1]);
						auto n = analysis.findNode(min);
						if(n && n.p==min)
						{
							max = min + analysis.getNodeSize(n);
							if(max-min > 0x200)
								max = min + 0x200;
						}
						else
							max = min + 0x100;
					}
					else
						min = fromHex(args[1]), max = fromHex(args[2]);
					auto event = cast(MemoryDumpEvent)log.events[analysis.cursor];
					if(event is null && analysis.cursor>0) event = cast(MemoryDumpEvent)log.events[analysis.cursor-1];
					if(event is null) throw new Exception("This is not a memory dump/map event.");
					bool found;
					foreach(int poolNr, ref pool;event.pools)
						if(pool.addr<=min && pool.topAddr>=max)
						{
							if(max>pool.topCommittedAddr) throw new Exception("Specified address range intersects a reserved memory region");
							found = true;
							ubyte[] data = event.loadPoolData(poolNr)[min-pool.addr .. max-pool.addr];
							foreach(i,v;data)
							{
								if(i%16==0)
									writef("%08X: ", i+min);
								else
								if(i%8==0)
									writef(" ");
								writef("%02X ", v);
								if(i%16==15 || i==data.length-1)
								{	
									for(int l=i+1;l<16;l++)
									{
										if(l%8==0)
											writef(" ");
										writef("   ");
									}
									writef("| ");
									foreach(vv;data[i&~15..i+1])
										if(vv==0)
											writef(" ");
										else if(vv<32 || vv>=127)
											writef(".");
										else
											writef(cast(char)vv);
									writefln;
								}
							}
						}
					if(!found)
						throw new Exception("Specified address range does not belong in any pool.");
					break;
				}
				case "n":
				case "next":
					analysis.goTo(analysis.cursor+1);
					break;
				case "p":
				case "prev":
				case "back":
					analysis.goTo(analysis.cursor-1, &progressCallback);
					break;
				case "pd":
				case "pdump":
				case "prevdump":
					for(int i=analysis.cursor-1;i>=0;i--)
						if(log.events[i].type==PACKET_MEMORY_DUMP)
							{ analysis.goTo(i, &progressCallback); goto Lbreak; }
					throw new Exception("Not found");
				case "pm":
				case "pmap":
				case "prevmap":
					for(int i=analysis.cursor-1;i>=0;i--)
						if(log.events[i].type==PACKET_MEMORY_MAP)
							{ analysis.goTo(i, &progressCallback); goto Lbreak; }
					throw new Exception("Not found");
				case "nd":
				case "ndump":
				case "nextdump":
					for(int i=analysis.cursor+1;i<log.events.length;i++)
						if(log.events[i].type==PACKET_MEMORY_DUMP)
							{ analysis.goTo(i, &progressCallback); goto Lbreak; }
					throw new Exception("Not found");
				case "nm":
				case "nmap":
				case "nextmap":
					for(int i=analysis.cursor+1;i<log.events.length;i++)
						if(log.events[i].type==PACKET_MEMORY_MAP)
							{ analysis.goTo(i, &progressCallback); goto Lbreak; }
					throw new Exception("Not found");
				case "ld":
				case "ldump":
				case "lastdump":
					for(int i=log.events.length-1;i>=0;i--)
						if(log.events[i].type==PACKET_MEMORY_DUMP)
							{ analysis.goTo(i, &progressCallback); goto Lbreak; }
					throw new Exception("Not found");
				case "lm":
				case "lmap":
				case "lastmap":
					for(int i=log.events.length-1;i>=0;i--)
						if(log.events[i].type==PACKET_MEMORY_MAP)
							{ analysis.goTo(i, &progressCallback); goto Lbreak; }
					throw new Exception("Not found");
Lbreak:
					break;
				case "integrity": // debug
				{
					int count = 0;
					for(auto n = analysis.first;n;n=n.next)
					{
						count++;
						assert(n.prev is null ? n is analysis.first : n is n.prev.next, "Broken chain");
						assert(n.next is null ? n is analysis.last  : n is n.next.prev, "Broken chain");
						auto event = cast(MemoryAllocationEvent)log.events[n.eventID];
						assert(event, "Invalid event");
						assert(n.p == event.p, "Node/Event pointer mismatch");
						if(n.next) assert(n.p+event.size <= n.next.p, "Node continuity broken");
						if(n.prev && (n.prev.p>>16) < (n.p>>16)) assert(analysis.map[n.p>>16] is n, "Node is not mapped");
					}
					writefln("%d nodes checked.", count);
					foreach(seg,n;analysis.map)
						if(n)
						{
							if(n.prev)
								assert(n.prev.p>>16 < seg, "Mapped node is not first");
							if(n.p>>16 < seg) // stretches across segs
								assert(n.next is null || (n.next.p>>16) >= seg, "Mismapped node");
							else
								assert(n.p>>16 == seg, "Mismapped node");
						}
					writefln("Map checked.");
					break;
				}
				case "freecheck":
					analysis.freeCheck = !analysis.freeCheck;
					writefln("Free node verification is %s.", analysis.freeCheck?"ON":"OFF");
					break;
				case "exit":
				case "halt":
				case "quit":
				case "q":
					return 0;
				default:
					writefln("Unknown command.");
					break;
			}
		catch(Exception e)
			writefln("Error: %s", e.msg);
	}
	assert(0);
}

uint fromHex(string s)
{
	uint result = 0xBAADDA7A;
	if(!sscanf(toStringz(s), "%x", &result))
		throw new Exception(format("%s is not a valid hex integer", s));
	/+if(result == 0xBAADDA7A)
		throw new Exception(format("%s is not a valid hex integer", s));+/
	return result;
}

string timeStr(time_t time)
{
	char[12] s;
	strftime(s.ptr, s.length, "%H:%M:%S", localtime(&time));
	return toString(s.dup.ptr);
}

string findMostRecent(string pattern)
{
	d_time newestTime;
	string newestFile;
	foreach(file;listdir("."))
		if(fnmatch(file, pattern))
		{
			d_time c, a, m;
			getTimes(file, c, a, m);
			if(m > newestTime)
			{
				newestTime = m;
				newestFile = file;
			}
		}
	return newestFile;
}

version(Windows)
{
	extern(Windows) extern bool SetConsoleTextAttribute(uint, ushort);
	extern(Windows) extern uint GetStdHandle(int);
	enum
	{
		STD_OUTPUT_HANDLE = -11
	}

	/// Emphasized text
	void highVideo()
	{
		fflush(stdout);
		SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), 15);
	}

	/// Darker text
	void lowVideo()
	{
		fflush(stdout);
		SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), 8);
	}

	/// Normal text
	void normVideo()
	{
		fflush(stdout);
		SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), 7);
	}
}
else
version(linux)
{
	/// Emphasized text
	void highVideo()
	{
		// TODO
	}

	/// Darker text
	void lowVideo()
	{
		// TODO
	}

	/// Normal text
	void normVideo()
	{
		// TODO
	}
}
else
{
	/// Emphasized text
	void highVideo() { }

	/// Darker text
	void lowVideo() { }

	/// Normal text
	void normVideo() { }
}