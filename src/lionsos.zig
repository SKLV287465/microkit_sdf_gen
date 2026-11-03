const std = @import("std");
const mod_sdf = @import("sdf.zig");
const mod_vmm = @import("vmm.zig");
const sddf = @import("sddf/sddf.zig");
const data = @import("data.zig");
const log = @import("log.zig");
const dtb = @import("dtb.zig");
const Allocator = std.mem.Allocator;

const SystemDescription = mod_sdf.SystemDescription;
const Pd = SystemDescription.ProtectionDomain;
const Mr = SystemDescription.MemoryRegion;
const Map = SystemDescription.Map;
const Channel = SystemDescription.Channel;

const ConfigResources = data.Resources;

const Blk = sddf.Blk;
const Net = sddf.Net;
const Serial = sddf.Serial;
const Timer = sddf.Timer;

const VirtualMachineSystem = mod_vmm;

fn fmt(allocator: Allocator, comptime s: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(allocator, s, args) catch @panic("OOM");
}

pub const FileSystem = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    fs: *Pd,
    client: *Pd,
    // The user can optionally override the data region MR
    data_mr: ?Mr,
    data_size: usize,
    completion_queue_size: usize,
    command_queue_size: usize,

    server_config: ConfigResources.Fs.Server,
    client_config: ConfigResources.Fs.Client,

    const Options = struct {
        data_mr: ?Mr = null,
        data_size: usize = 1024 * 1024 * 64,
        // TODO: do the queue sizes need to be the same?
        completion_queue_size: usize = 0x8000,
        command_queue_size: usize = 0x8000,
    };

    const Region = enum {
        data,
        command_queue,
        completion_queue,
    };

    const Error = error{
        InvalidClient,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, fs: *Pd, client: *Pd, options: Options) Error!FileSystem {
        if (std.mem.eql(u8, fs.name, client.name)) {
            log.err("invalid file system client, same name as file system PD '{s}", .{client.name});
            return Error.InvalidClient;
        }
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .fs = fs,
            .client = client,
            .data_mr = options.data_mr,
            .data_size = options.data_size,
            .completion_queue_size = options.completion_queue_size,
            .command_queue_size = options.command_queue_size,

            .server_config = std.mem.zeroInit(ConfigResources.Fs.Server, .{}),
            .client_config = std.mem.zeroInit(ConfigResources.Fs.Client, .{}),
        };
    }

    fn createMapping(fs: *Pd, map: Map) void {
        if (fs.vm) |vm| {
            vm.addMap(map);
        } else {
            fs.addMap(map);
        }
    }

    const ConnectOptions = struct {
        cached: ?bool = null,
        command_vaddr: ?u64 = null,
        completion_vaddr: ?u64 = null,
        share_vaddr: ?u64 = null,
    };

    pub fn connect(system: *FileSystem, options: ConnectOptions) void {
        const allocator = system.allocator;
        const fs = system.fs;
        const client = system.client;

        const fs_command_queue = Mr.create(allocator, fmt(allocator, "fs_{s}_command_queue", .{fs.name}), system.command_queue_size, .{});
        const fs_completion_queue = Mr.create(allocator, fmt(allocator, "fs_{s}_completion_queue", .{fs.name}), system.completion_queue_size, .{});

        system.sdf.addMemoryRegion(fs_command_queue);
        system.sdf.addMemoryRegion(fs_completion_queue);

        const fs_share = blk: {
            if (system.data_mr) |data_mr| {
                break :blk data_mr;
            } else {
                const mr = Mr.create(allocator, fmt(allocator, "fs_{s}_share", .{fs.name}), system.data_size, .{});
                system.sdf.addMemoryRegion(mr);
                break :blk mr;
            }
        };

        const server_command_map = Map.create(fs_command_queue, options.command_vaddr orelse fs.getMapVaddr(&fs_command_queue), .rw, .{ .cached = options.cached });
        system.server_config.client.command_queue = .createFromMap(server_command_map);
        createMapping(fs, server_command_map);

        const server_completion_map = Map.create(fs_completion_queue, options.completion_vaddr orelse fs.getMapVaddr(&fs_completion_queue), .rw, .{ .cached = options.cached });
        system.server_config.client.completion_queue = .createFromMap(server_completion_map);
        createMapping(fs, server_completion_map);

        const server_share_map = Map.create(fs_share, options.share_vaddr orelse fs.getMapVaddr(&fs_share), .rw, .{ .cached = options.cached });
        system.server_config.client.share = .createFromMap(server_share_map);
        createMapping(fs, server_share_map);

        const client_command_map = Map.create(fs_command_queue, client.getMapVaddr(&fs_command_queue), .rw, .{ .cached = options.cached });
        system.client.addMap(client_command_map);
        system.client_config.server.command_queue = .createFromMap(client_command_map);

        const client_completion_map = Map.create(fs_completion_queue, client.getMapVaddr(&fs_completion_queue), .rw, .{ .cached = options.cached });

        system.client.addMap(client_completion_map);
        system.client_config.server.completion_queue = .createFromMap(client_completion_map);

        const client_share_map = Map.create(fs_share, client.getMapVaddr(&fs_share), .rw, .{ .cached = options.cached });
        system.client.addMap(client_share_map);
        system.client_config.server.share = .createFromMap(client_share_map);

        system.server_config.client.queue_len = 512;
        system.client_config.server.queue_len = 512;

        const channel = Channel.create(system.fs, system.client, .{}) catch @panic("failed to create connection channel");
        system.sdf.addChannel(channel);
        system.server_config.client.id = channel.pd_a_id;
        system.client_config.server.id = channel.pd_b_id;
    }

    pub fn serialiseConfig(system: *FileSystem, prefix: []const u8) !void {
        const allocator = system.allocator;

        const server_config = fmt(allocator, "fs_server_{s}", .{system.fs.name});
        try data.serialize(allocator, system.server_config, prefix, server_config);

        const client_config = fmt(allocator, "fs_client_{s}", .{system.client.name});
        try data.serialize(allocator, system.client_config, prefix, client_config);
    }

    pub const Nfs = struct {
        allocator: Allocator,
        fs: FileSystem,
        data: ConfigResources.Nfs,
        serial: *Serial,
        timer: *Timer,
        net: *Net,
        net_copier: *Pd,
        mac_addr: ?[]const u8,

        const Error = FileSystem.Error || Net.Error;

        pub const Options = struct {
            server: []const u8,
            export_path: []const u8,
            mac_addr: ?[]const u8 = null,
        };

        pub fn init(allocator: Allocator, sdf: *SystemDescription, fs: *Pd, client: *Pd, net: *Net, net_copier: *Pd, serial: *Serial, timer: *Timer, options: Nfs.Options) Nfs.Error!Nfs {
            var nfs_data = std.mem.zeroInit(ConfigResources.Nfs, .{});
            std.mem.copyForwards(u8, &nfs_data.server, options.server);
            std.mem.copyForwards(u8, &nfs_data.export_path, options.export_path);

            const mac_addr = if (options.mac_addr) |m| allocator.dupe(u8, m) catch @panic("OOM") else null;

            return .{
                .allocator = allocator,
                .fs = try FileSystem.init(allocator, sdf, fs, client, .{}),
                .data = nfs_data,
                .serial = serial,
                .timer = timer,
                .net = net,
                .net_copier = net_copier,
                .mac_addr = mac_addr,
            };
        }

        pub fn deinit(nfs: *Nfs) void {
            if (nfs.mac_addr) |mac_addr| {
                nfs.allocator.free(mac_addr);
            }
        }

        pub fn connect(nfs: *Nfs) !void {
            const fs_pd = nfs.fs.fs;
            // NFS depends on being connected via the network, serial, and timer sub-sytems.
            try nfs.net.addClientWithCopier(fs_pd, nfs.net_copier, .{
                .mac_addr = nfs.mac_addr,
            });
            try nfs.serial.addClient(fs_pd);
            try nfs.timer.addClient(fs_pd);

            nfs.fs.connect(.{});
        }

        pub fn serialiseConfig(nfs: *Nfs, prefix: []const u8) !void {
            try data.serialize(nfs.allocator, nfs.data, prefix, "nfs_config");
            try nfs.fs.serialiseConfig(prefix);
        }
    };

    pub const Fat = struct {
        allocator: Allocator,
        fs: FileSystem,
        data: ConfigResources.Fs,
        blk: *Blk,
        partition: u32,

        pub const Options = struct {
            partition: u32,
        };

        pub fn init(allocator: Allocator, sdf: *SystemDescription, fs: *Pd, client: *Pd, blk: *Blk, options: Fat.Options) Error!Fat {
            return .{
                .allocator = allocator,
                .fs = try FileSystem.init(allocator, sdf, fs, client, .{}),
                .blk = blk,
                .partition = options.partition,
                .data = std.mem.zeroInit(ConfigResources.Fs, .{}),
            };
        }

        pub fn connect(fat: *Fat) !void {
            const allocator = fat.allocator;
            const sdf = fat.fs.sdf;
            const fs_pd = fat.fs.fs;

            try fat.blk.addClient(fs_pd, .{
                .partition = fat.partition,
            });
            fat.fs.connect(.{});
            // Special things for FATFS
            const stack1 = Mr.create(allocator, fmt(allocator, "{s}_stack1", .{fs_pd.name}), 0x40_000, .{});
            const stack2 = Mr.create(allocator, fmt(allocator, "{s}_stack2", .{fs_pd.name}), 0x40_000, .{});
            const stack3 = Mr.create(allocator, fmt(allocator, "{s}_stack3", .{fs_pd.name}), 0x40_000, .{});
            const stack4 = Mr.create(allocator, fmt(allocator, "{s}_stack4", .{fs_pd.name}), 0x40_000, .{});
            sdf.addMemoryRegion(stack1);
            sdf.addMemoryRegion(stack2);
            sdf.addMemoryRegion(stack3);
            sdf.addMemoryRegion(stack4);
            fs_pd.addMap(.create(stack1, 0xA0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_one" }));
            fs_pd.addMap(.create(stack2, 0xB0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_two" }));
            fs_pd.addMap(.create(stack3, 0xC0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_three" }));
            fs_pd.addMap(.create(stack4, 0xD0_000_000, .rw, .{ .setvar_vaddr = "worker_thread_stack_four" }));
        }

        pub fn serialiseConfig(fat: *Fat, prefix: []const u8) !void {
            try data.serialize(fat.allocator, fat.data, prefix, "fat_config");
            try fat.fs.serialiseConfig(prefix);
        }
    };

    pub const VmFs = struct {
        fs: FileSystem,
        data: ConfigResources.Fs,
        fs_vm_sys: *VirtualMachineSystem,
        blk: *Blk,
        virtio_device: *dtb.Node,
        partition: u32,

        const Error = FileSystem.Error;

        const UIO_SHARED_CONFIG = "vmfs_config";
        const UIO_CMD = "vmfs_command";
        const UIO_COMP = "vmfs_completion";
        const UIO_DATA = "vmfs_data";
        const UIO_FAULT = "vmfs_fault";

        const NUM_UIO_REGIONS = 5;

        pub const Options = struct {
            partition: u32,
        };

        pub fn init(allocator: Allocator, sdf: *SystemDescription, fs_vm_sys: *VirtualMachineSystem, client: *Pd, blk: *Blk, virtio_device: *dtb.Node, options: VmFs.Options) VmFs.Error!VmFs {
            return .{
                .fs_vm_sys = fs_vm_sys,
                .fs = try FileSystem.init(allocator, sdf, fs_vm_sys.vmm, client, .{}),
                .data = std.mem.zeroInit(ConfigResources.Fs, .{}),
                .blk = blk,
                .virtio_device = virtio_device,
                .partition = options.partition,
            };
        }

        pub fn connect(vmfs: *VmFs) !void {
            if (!vmfs.fs_vm_sys.connected) {
                log.err("The FS driver VM system must be connected before the FS.", .{});
                return error.OutOfOrderConnection;
            }
            if (vmfs.blk.connected) {
                log.err("The Block system must be connected after the FS.", .{});
                return error.OutOfOrderConnection;
            }
            if (vmfs.blk.serialised or vmfs.fs_vm_sys.serialised) {
                log.err("Serialisation must take place after all conections", .{});
                return error.OutOfOrderSerialisation;
            }

            if (vmfs.fs_vm_sys.data.num_linux_uio_regions != NUM_UIO_REGIONS) {
                log.err("The FS driver VM does not have the required 5 UIO regions, got {d}", .{vmfs.fs_vm_sys.data.num_linux_uio_regions});
                return error.InvalidVMConf;
            }

            try vmfs.fs_vm_sys.addVirtioMmioBlk(vmfs.virtio_device, vmfs.blk, .{
                .partition = vmfs.partition,
            });

            // Figure out where all the FS regions are supposed to go from DTB
            const compatible = dtb.LinuxUio.compatible;
            // Error checking below assumes a single compatible string.
            std.debug.assert(compatible.len == 1);
            const conf_uio_reg = vmfs.fs_vm_sys.findUio(UIO_SHARED_CONFIG) orelse {
                log.err("failed to find UIO FS shared config node: expected node with compatible '{s}\\0{s}'", .{ compatible[0], UIO_SHARED_CONFIG });
                return error.InvalidVMConf;
            };
            const cmd_uio_reg = vmfs.fs_vm_sys.findUio(UIO_CMD) orelse {
                log.err("failed to find UIO FS command node: expected node with compatible '{s}\\0{s}'", .{ compatible[0], UIO_CMD });
                return error.InvalidVMConf;
            };
            const comp_uio_reg = vmfs.fs_vm_sys.findUio(UIO_COMP) orelse {
                log.err("failed to find UIO FS completion node: expected node with compatible '{s}\\0{s}'", .{ compatible[0], UIO_COMP });
                return error.InvalidVMConf;
            };
            const data_uio_reg = vmfs.fs_vm_sys.findUio(UIO_DATA) orelse {
                log.err("failed to find UIO FS data node: expected node with compatible '{s}\\0{s}'", .{ compatible[0], UIO_DATA });
                return error.InvalidVMConf;
            };

            if (vmfs.fs_vm_sys.findUio(UIO_FAULT) == null) {
                log.err("failed to find UIO FS fault data node: expected node with compatible '{s}\\0{s}'", .{ compatible[0], UIO_FAULT });
                return error.InvalidVMConf;
            }

            const cmd_guest_paddr = cmd_uio_reg.guest_paddr;
            const comp_guest_paddr = comp_uio_reg.guest_paddr;
            const data_guest_paddr = data_uio_reg.guest_paddr;
            vmfs.fs.connect(.{ .cached = false, .command_vaddr = cmd_guest_paddr, .completion_vaddr = comp_guest_paddr, .share_vaddr = data_guest_paddr });

            // Set up the shared configs region between guest and VMM
            const allocator = vmfs.fs.allocator;
            const config_share_size = conf_uio_reg.size;
            const config_share_guest_paddr = conf_uio_reg.guest_paddr;
            const config_share_region = Mr.create(allocator, fmt(allocator, "fs_{s}_guest_conf_share", .{vmfs.fs_vm_sys.guest.name}), config_share_size, .{});
            vmfs.fs_vm_sys.sdf.addMemoryRegion(config_share_region);

            // Finally map everything in
            const guest_config_share_map = Map.create(config_share_region, config_share_guest_paddr, .rw, .{ .cached = false });
            vmfs.fs_vm_sys.guest.addMap(guest_config_share_map);

            const vmm_config_share_map_vaddr = vmfs.fs_vm_sys.vmm.getMapVaddr(&config_share_region);
            const vmm_config_share_map = Map.create(config_share_region, vmm_config_share_map_vaddr, .rw, .{ .cached = false });
            vmfs.fs_vm_sys.vmm.addMap(vmm_config_share_map);

            // Update the UIO book keeping data in the VM system. This is why config serialisation must be deferred until everything is set up.
            conf_uio_reg.vmm_vaddr = vmm_config_share_map_vaddr;
        }

        pub fn serialiseConfig(vmfs: *VmFs, prefix: []const u8) !void {
            try data.serialize(vmfs.fs.allocator, vmfs.data, prefix, "vmfs_config");
            try vmfs.fs.serialiseConfig(prefix);
        }
    };
};

pub const Pager = struct {
    allocator: Allocator,
    sdf: *SystemDescription,
    pager: *Pd,
    clients: std.array_list.Managed(*Pd),
    memory_size: usize,
    bootinfo_size: usize,
    mmap_base: u64,
    brk_base: u64,
    sched_control_core: ?u8,
    fork_slots: u8,
    /// The systems whose clients' forks the pager connects to spare connections.
    serial: ?*Serial = null,
    net: ?*Net = null,
    connected: bool = false,
    serialised: bool = false,

    server_config: ConfigResources.Pager.Server,
    client_configs: std.array_list.Managed(ConfigResources.Pager.Client),

    const Error = sddf.SystemError || error{ TooManyClients, InvalidSpare, TooManySpares };

    /// The CNodes the pager receives the caps it creates at runtime into, as
    /// (name, root CSpace slot, size_bits, post_capdl_untypeds). Slot 0 is reserved for
    /// the Microkit CNode, so these start at 1.
    const CNodes = struct {
        name: []const u8,
        slot: u8,
        size_bits: u8,
        post_capdl_untypeds: bool,
    };
    const cnodes = [_]CNodes{
        // All untyped memory left after initialisation.
        .{ .name = "untypeds", .slot = 1, .size_bits = 9, .post_capdl_untypeds = true },
        // Frames the pager retypes to satisfy faults.
        .{ .name = "frames", .slot = 2, .size_bits = 20, .post_capdl_untypeds = false },
        // Intermediate paging structures (PUD/PD/PT).
        .{ .name = "paging_structures", .slot = 3, .size_bits = 20, .post_capdl_untypeds = false },
        // Copies of the global zero page cap, one per read-only mapping.
        .{ .name = "zero_page_copies", .slot = 4, .size_bits = 20, .post_capdl_untypeds = false },
        // What fork() creates for each process, in a fixed block of slots per process.
        .{ .name = "process_cspaces", .slot = 5, .size_bits = 7, .post_capdl_untypeds = false },
        // The clients' ELF frames, populated by the Microkit tool.
        .{ .name = "elf_caps", .slot = 6, .size_bits = 12, .post_capdl_untypeds = false },
        // Copies of frame caps. A frame cap carries its own mapping, so a folio mapped
        // into more than one VSpace needs a cap per mapping.
        .{ .name = "frame_copies", .slot = 7, .size_bits = 20, .post_capdl_untypeds = false },
        // Caps the Microkit tool hands the pager for the processes it creates at runtime,
        // starting with a copy of its own endpoint at PAGER_SELF_EP_SLOT, then caps to each
        // peer's Microkit CNode and notification (see peerCNodeSlot()). Slot 0 of every
        // CNode here is its self-reference.
        .{ .name = "pager_caps", .slot = 8, .size_bits = 6, .post_capdl_untypeds = false },
        // Frame caps of every spare connection's regions.
        .{ .name = "connection_frames", .slot = 10, .size_bits = 13, .post_capdl_untypeds = false },
    };

    /// Where the caps to a peer -- a PD a forked process is connected to -- go in pager_caps.
    /// Must match PAGER_PEER_*_SLOT in lions/pager/config.h, which also reserves slot 2.
    fn peerCNodeSlot(peer: usize) u64 {
        return 4 + 2 * peer;
    }
    fn peerNtfnSlot(peer: usize) u64 {
        return 5 + 2 * peer;
    }

    const sched_control_slot = 9;

    pub const Options = struct {
        /// Scratch memory for folio metadata and the shadow page tables
        memory_size: usize = 0x2000000,
        bootinfo_size: usize = 0x2000,
        /// Where in each client's address space its mmap arena and heap begin
        mmap_base: u64 = 0x8000000000,
        brk_base: u64 = 0x7000000000,
        sched_control_core: ?u8 = 0,
        /// How many spare connections to each system added with addSerial()/addNet() there
        /// are for forked processes to take.
        fork_slots: u8 = 2,
    };

    pub fn init(allocator: Allocator, sdf: *SystemDescription, pager: *Pd, options: Options) Pager {
        return .{
            .allocator = allocator,
            .sdf = sdf,
            .pager = pager,
            .clients = std.array_list.Managed(*Pd).init(allocator),
            .memory_size = options.memory_size,
            .bootinfo_size = options.bootinfo_size,
            .mmap_base = options.mmap_base,
            .brk_base = options.brk_base,
            .sched_control_core = options.sched_control_core,
            .fork_slots = options.fork_slots,
            .server_config = std.mem.zeroInit(ConfigResources.Pager.Server, .{}),
            .client_configs = std.array_list.Managed(ConfigResources.Pager.Client).init(allocator),
        };
    }

    pub fn deinit(system: *Pager) void {
        system.clients.deinit();
        system.client_configs.deinit();
    }

    pub fn addClient(system: *Pager, client: *Pd) Error!void {
        if (std.mem.eql(u8, client.name, system.pager.name)) {
            log.err("invalid pager client, same name as pager PD '{s}'", .{client.name});
            return Error.InvalidClient;
        }
        for (system.clients.items) |existing_client| {
            if (std.mem.eql(u8, existing_client.name, client.name)) {
                return Error.DuplicateClient;
            }
        }
        if (system.clients.items.len == ConfigResources.Pager.MaxClients) {
            log.err("failed to add client '{s}' to pager '{s}', maximum clients reached", .{ client.name, system.pager.name });
            return Error.TooManyClients;
        }

        // The client's stack pages are left unmapped at boot so that they fault in
        // through the pager -- that is the whole point of being paged.
        client.backed = false;

        system.clients.append(client) catch @panic("Could not add client to Pager");
        system.client_configs.append(std.mem.zeroInit(ConfigResources.Pager.Client, .{})) catch @panic("Could not add client config to Pager");
    }

    /// Gives the processes forked from clients of `serial` a spare serial connection each.
    /// Must be called before `serial` is connected, and the pager connected after it.
    pub fn addSerial(system: *Pager, serial: *Serial) void {
        serial.addSpareClients(system.fork_slots);
        system.serial = serial;
    }

    /// Gives the processes forked from clients of `net` a spare net connection each, with
    /// one of `copiers` copying its received packets. There must be one copier per fork
    /// slot. Must be called before `net` is connected, and the pager connected after it.
    pub fn addNet(system: *Pager, net: *Net, copiers: []const *Pd) !void {
        if (copiers.len != system.fork_slots) {
            log.err("pager '{s}' has {} fork slots but was given {} net copiers", .{ system.pager.name, system.fork_slots, copiers.len });
            return Error.InvalidSpare;
        }
        try net.addSpareClients(copiers);
        system.net = net;
    }

    fn indexOfPd(pds: []const *Pd, pd: *const Pd) ?usize {
        for (pds, 0..) |other, i| {
            if (std.mem.eql(u8, other.name, pd.name)) return i;
        }
        return null;
    }

    fn addConnTemplate(client: *ConfigResources.Pager.ClientConnection, kind: ConfigResources.Pager.ConnKind, client_id: u8, regions: []const ConfigResources.Region) void {
        var conn = &client.conns[client.num_conns];
        conn.kind = @intFromEnum(kind);
        conn.client_id = client_id;
        conn.num_regions = @intCast(regions.len);
        for (regions, 0..) |region, i| conn.regions[i] = region;
        client.num_conns += 1;
    }

    /// Records the connections each client has, for its forks to get a spare copy of.
    fn connectTemplates(system: *Pager) void {
        for (system.clients.items, 0..) |client, i| {
            const pager_client = &system.server_config.clients[i];
            if (system.serial) |serial| {
                if (indexOfPd(serial.clients.items, client)) |j| {
                    const config = serial.client_configs.items[j];
                    addConnTemplate(pager_client, .serial_tx, config.tx.id, &.{ config.tx.queue, config.tx.data });
                    if (serial.hasRx()) {
                        addConnTemplate(pager_client, .serial_rx, config.rx.id, &.{ config.rx.queue, config.rx.data });
                    }
                }
            }
            if (system.net) |net| {
                if (indexOfPd(net.clients.items, client)) |j| {
                    const config = net.client_configs.items[j];
                    const info = net.client_info.items[j];
                    if (info.tx) {
                        addConnTemplate(pager_client, .net_tx, config.tx.id, &.{ config.tx.free_queue, config.tx.active_queue, config.tx_data });
                    }
                    // A spare receives through a copier, so only a client with one can be
                    // given a spare in its place.
                    if (info.rx and net.copiers.items[j] != null) {
                        addConnTemplate(pager_client, .net_rx, config.rx.id, &.{ config.rx.free_queue, config.rx.active_queue, config.rx_data });
                    }
                }
            }
        }
    }

    const SpareBuilder = struct {
        system: *Pager,
        peers: std.array_list.Managed(*Pd),
        next_frame: u64 = 1,

        fn peerIndex(builder: *SpareBuilder, peer: *Pd) Error!u8 {
            if (indexOfPd(builder.peers.items, peer)) |i| return @intCast(i);
            if (builder.peers.items.len == ConfigResources.Pager.MaxPeers) return Error.TooManySpares;
            builder.peers.append(peer) catch @panic("OOM");
            return @intCast(builder.peers.items.len - 1);
        }

        fn add(builder: *SpareBuilder, kind: ConfigResources.Pager.ConnKind, peer: *Pd, peer_id: u8, mrs: []const Mr, mac_addr: [6]u8) Error!void {
            const system = builder.system;
            const config = &system.server_config;
            if (config.num_spares == ConfigResources.Pager.MaxSpares) return Error.TooManySpares;
            var spare = &config.spares[config.num_spares];
            spare.kind = @intFromEnum(kind);
            spare.peer = try builder.peerIndex(peer);
            spare.peer_id = peer_id;
            spare.num_regions = @intCast(mrs.len);
            spare.mac_addr = mac_addr;
            const page_size = Mr.PageSize.small.toInt(system.sdf.arch);
            for (mrs, 0..) |mr, i| {
                const num_frames = mr.size / page_size;
                system.pager.addCapMap(SystemDescription.CapMap.createInCNode(system.allocator, "frames", mr.name, "connection_frames", builder.next_frame));
                spare.frames[i] = @intCast(builder.next_frame);
                spare.num_frames[i] = @intCast(num_frames);
                builder.next_frame += num_frames;
            }
            config.num_spares += 1;
        }
    };

    /// Hands the pager the spare connections of the systems added with addSerial() and
    /// addNet(): the frames of each, and caps to the Microkit CNode and notification of
    /// each PD on the other end, its peer.
    fn connectSpares(system: *Pager) Error!void {
        var builder: SpareBuilder = .{
            .system = system,
            .peers = std.array_list.Managed(*Pd).init(system.allocator),
        };
        defer builder.peers.deinit();
        const no_mac = std.mem.zeroes([6]u8);

        if (system.serial) |serial| {
            if (!serial.connected) return Error.NotConnected;
            for (serial.spares.items) |spare| {
                try builder.add(.serial_tx, serial.virt_tx, spare.tx_id, &spare.tx_mrs, no_mac);
                if (spare.rx_mrs) |rx_mrs| {
                    try builder.add(.serial_rx, serial.virt_rx.?, spare.rx_id, &rx_mrs, no_mac);
                }
            }
        }
        if (system.net) |net| {
            if (!net.connected) return Error.NotConnected;
            for (net.spares.items) |spare| {
                try builder.add(.net_tx, net.virt_tx, spare.tx_id, &spare.tx_mrs, no_mac);
                try builder.add(.net_rx, spare.copier, spare.rx_id, &spare.rx_mrs, spare.mac_addr);
            }
        }

        const frames_slots = @as(u64, 1) << @intCast(system.server_config.connection_frames.size_bits);
        if (builder.next_frame > frames_slots) {
            log.err("pager '{s}': the spare connections need {} frame slots, connection_frames has {}", .{ system.pager.name, builder.next_frame, frames_slots });
            return Error.TooManySpares;
        }

        for (builder.peers.items, 0..) |peer, i| {
            system.pager.addCapMap(SystemDescription.CapMap.createInCNode(system.allocator, "microkit_cnode", peer.name, "pager_caps", peerCNodeSlot(i)));
            system.pager.addCapMap(SystemDescription.CapMap.createInCNode(system.allocator, "notification", peer.name, "pager_caps", peerNtfnSlot(i)));
        }
        system.server_config.num_peers = @intCast(builder.peers.items.len);
    }

    pub fn connect(system: *Pager) !void {
        const allocator = system.allocator;
        const pager = system.pager;

        const memory = Mr.create(allocator, fmt(allocator, "{s}_memory", .{pager.name}), system.memory_size, .{});
        system.sdf.addMemoryRegion(memory);
        const memory_map = Map.create(memory, pager.getMapVaddr(&memory), .rw, .{});
        pager.addMap(memory_map);
        system.server_config.memory = .createFromMap(memory_map);

        // The Microkit tool fills this with a capDLBootInfo_t describing the untypeds
        // that survived system initialisation.
        const bootinfo = Mr.create(allocator, fmt(allocator, "{s}_bootinfo", .{pager.name}), system.bootinfo_size, .{
            .prefill_bootinfo = "post_capdl_untypeds",
        });
        system.sdf.addMemoryRegion(bootinfo);
        const bootinfo_map = Map.create(bootinfo, pager.getMapVaddr(&bootinfo), .rw, .{});
        pager.addMap(bootinfo_map);
        system.server_config.bootinfo = .createFromMap(bootinfo_map);

        inline for (cnodes) |spec| {
            const cnode = SystemDescription.CNode.create(allocator, spec.name, spec.post_capdl_untypeds, spec.size_bits);
            system.sdf.addCNode(cnode);
            // pd=null because these CNodes are the pager's alone, not shared.
            pager.addCapMap(SystemDescription.CapMap.create(allocator, "cnode", spec.name, null, spec.slot));
            @field(system.server_config, spec.name) = .{ .slot = spec.slot, .size_bits = spec.size_bits };
        }

        if (system.sched_control_core) |core| {
            pager.addCapMap(SystemDescription.CapMap.createSchedControl(allocator, core, sched_control_slot));
            system.server_config.sched_control = sched_control_slot;
        }

        pager.elf_caps_cnode = allocator.dupe(u8, "elf_caps") catch @panic("Could not dupe CNode name");
        // So that fork() can mint the endpoint caps a new process needs.
        pager.self_ep_cnode = allocator.dupe(u8, "pager_caps") catch @panic("Could not dupe CNode name");

        for (system.clients.items, 0..) |client, i| {
            // The client needs to be able to PPC into the pager for brk/mmap/munmap/fork.
            const ch = Channel.create(pager, client, .{ .pp = .b }) catch unreachable;
            system.sdf.addChannel(ch);

            // Allocate the fault id to match the client's index here, so that the pager
            // can use what fault() hands it to index its per-client state directly.
            const fault_id = try pager.addFaultClient(client, @intCast(i));

            // Resolved the way the Microkit tool resolves them, since the pager
            // configures each forked process' scheduling context itself.
            const budget: u64 = client.budget orelse 1000;
            system.server_config.clients[i] = .{
                .id = ch.pd_a_id,
                .fault_id = fault_id,
                .client_id = ch.pd_b_id,
                .priority = client.priority orelse 0,
                .mmap_base = system.mmap_base,
                .brk_base = system.brk_base,
                .budget = budget,
                .period = client.period orelse budget,
                .num_conns = 0,
                .conns = std.mem.zeroes([ConfigResources.Pager.MaxClientConns]ConfigResources.Pager.ConnTemplate),
            };
            system.client_configs.items[i] = .{
                .id = ch.pd_b_id,
                .mmap_base = system.mmap_base,
                .brk_base = system.brk_base,
            };
        }
        system.server_config.num_clients = @intCast(system.clients.items.len);

        system.connectTemplates();
        try system.connectSpares();

        system.connected = true;
    }

    pub fn serialiseConfig(system: *Pager, prefix: []const u8) !void {
        if (!system.connected) return Error.NotConnected;

        const allocator = system.allocator;

        const server_config = fmt(allocator, "pager_server_{s}", .{system.pager.name});
        try data.serialize(allocator, system.server_config, prefix, server_config);

        for (system.clients.items, 0..) |client, i| {
            const client_config = fmt(allocator, "pager_client_{s}", .{client.name});
            try data.serialize(allocator, system.client_configs.items[i], prefix, client_config);
        }

        system.serialised = true;
    }
};
