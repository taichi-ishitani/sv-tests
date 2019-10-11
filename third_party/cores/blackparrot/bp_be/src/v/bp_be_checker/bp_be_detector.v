/**
 *
 * Name:
 *   bp_be_detector.v
 * 
 * Description:
 *   
 *
 * Notes:
 *   We don't need the entirety of the calc_status structure here, but for simplicity 
 *     we pass it all. If the compiler doesn't flatten and optimize, we can do it ourselves.
 *   We should get rid of the magic numbers here and replace with constants based on pipeline
 *     stages. However, like the calculator, this is a high risk change that should be postponed
 */

module bp_be_detector 
 import bp_common_pkg::*;
 import bp_common_aviary_pkg::*;
 import bp_common_rv64_pkg::*;
 import bp_be_pkg::*;
 #(parameter bp_cfg_e cfg_p = e_bp_inv_cfg
   `declare_bp_proc_params(cfg_p)

   // Generated parameters
   , localparam isd_status_width_lp = `bp_be_isd_status_width
   , localparam calc_status_width_lp = `bp_be_calc_status_width(vaddr_width_p, branch_metadata_fwd_width_p)
   )
  (input                               clk_i
   , input                             reset_i

   // Dependency information
   , input [isd_status_width_lp-1:0]   isd_status_i
   , input [calc_status_width_lp-1:0]  calc_status_i
   , input [vaddr_width_p-1:0]         expected_npc_i
   , input                             mmu_cmd_ready_i
   , input                             credits_full_i
   , input                             credits_empty_i

   , input                             flush_i

   // Pipeline control signals from the checker to the calculator
   , output                            chk_dispatch_v_o
   , output                            chk_roll_o
   , output                            chk_poison_iss_o
   , output                            chk_poison_isd_o
   , output                            chk_poison_ex1_o
   , output                            chk_poison_ex2_o
  );

`declare_bp_be_internal_if_structs(vaddr_width_p, paddr_width_p, asid_width_p, branch_metadata_fwd_width_p); 

// Casting 
bp_be_isd_status_s       isd_status_cast_i;
bp_be_calc_status_s      calc_status_cast_i;
bp_be_dep_status_s [4:0] dep_status_li;

assign isd_status_cast_i  = isd_status_i;
assign calc_status_cast_i = calc_status_i;
assign dep_status_li      = calc_status_cast_i.dep_status;

// Suppress unused inputs
wire unused = &{clk_i, reset_i};

// Declare intermediate signals
// Integer data hazards
logic [2:0] irs1_data_haz_v , irs2_data_haz_v;
// Floating point data hazards
logic [2:0] frs1_data_haz_v , frs2_data_haz_v;
logic [2:0] rs1_match_vector, rs2_match_vector;

logic fence_haz_v, serial_haz_v, data_haz_v, struct_haz_v, mispredict_v, mem_in_pipe_v;

always_comb 
  begin
    // Generate matches for rs1 and rs2.
    // 3 stages because we only care about ex1, ex2, and iwb dependencies. fwb dependencies
    //   can be handled through forwarding
    for(integer i = 0; i < 3; i++) 
      begin
        rs1_match_vector[i] = (isd_status_cast_i.isd_rs1_addr != '0)
                              & (isd_status_cast_i.isd_rs1_addr == dep_status_li[i].rd_addr);

        rs2_match_vector[i] = (isd_status_cast_i.isd_rs2_addr != '0)
                              & (isd_status_cast_i.isd_rs2_addr == dep_status_li[i].rd_addr);
      end

    // Detect integer and float data hazards for EX1
    irs1_data_haz_v[0] = (isd_status_cast_i.isd_irs1_v & rs1_match_vector[0])
                         & (dep_status_li[0].mul_iwb_v | dep_status_li[0].mem_iwb_v);

    irs2_data_haz_v[0] = (isd_status_cast_i.isd_irs2_v & rs2_match_vector[0])
                         & (dep_status_li[0].mul_iwb_v | dep_status_li[0].mem_iwb_v);

    frs1_data_haz_v[0] = (isd_status_cast_i.isd_frs1_v & rs1_match_vector[0])
                         & (dep_status_li[0].mem_fwb_v | dep_status_li[0].fp_fwb_v);

    frs2_data_haz_v[0] = (isd_status_cast_i.isd_frs2_v & rs2_match_vector[0])
                         & (dep_status_li[0].mem_fwb_v | dep_status_li[0].fp_fwb_v);

    // Detect integer and float data hazards for EX2
    irs1_data_haz_v[1] = (isd_status_cast_i.isd_irs1_v & rs1_match_vector[1])
                         & (dep_status_li[1].mem_iwb_v);

    irs2_data_haz_v[1] = (isd_status_cast_i.isd_irs2_v & rs2_match_vector[1])
                         & (dep_status_li[1].mem_iwb_v);

    frs1_data_haz_v[1] = (isd_status_cast_i.isd_frs1_v & rs1_match_vector[1])
                         & (dep_status_li[1].mem_fwb_v | dep_status_li[1].fp_fwb_v);

    frs2_data_haz_v[1] = (isd_status_cast_i.isd_frs2_v & rs2_match_vector[1])
                         & (dep_status_li[1].mem_fwb_v | dep_status_li[1].fp_fwb_v);

    // Detect float data hazards for IWB. Integer dependencies can be handled by forwarding
    irs1_data_haz_v[2] = '0;
    irs2_data_haz_v[2] = '0;

    frs1_data_haz_v[2] = (isd_status_cast_i.isd_frs1_v & rs1_match_vector[2])
                         & (dep_status_li[2].fp_fwb_v);

    frs2_data_haz_v[2] = (isd_status_cast_i.isd_frs2_v & rs2_match_vector[2])
                         & (dep_status_li[2].fp_fwb_v);

    mem_in_pipe_v      = dep_status_li[0].mem_v | dep_status_li[1].mem_v | dep_status_li[2].mem_v;
    fence_haz_v        = (isd_status_cast_i.isd_fence_v & (~credits_empty_i | mem_in_pipe_v))
                         | (isd_status_cast_i.isd_mem_v & credits_full_i);

    serial_haz_v       = dep_status_li[0].serial_v
                         | dep_status_li[1].serial_v
                         | dep_status_li[2].serial_v
                         | dep_status_li[3].serial_v;

    // Combine all data hazard information
    // TODO: Parameterize away floating point data hazards without hardware support
    data_haz_v = (|irs1_data_haz_v) 
                 | (|irs2_data_haz_v) 
                 | (|frs1_data_haz_v) 
                 | (|frs2_data_haz_v);

    // Combine all structural hazard information
    struct_haz_v = ~mmu_cmd_ready_i | fence_haz_v | serial_haz_v;

    // Detect misprediction
    mispredict_v = (calc_status_cast_i.ex1_v & (calc_status_cast_i.ex1_pc != expected_npc_i));
  end

// Generate calculator control signals
assign chk_dispatch_v_o = ~(data_haz_v | struct_haz_v); 
assign chk_roll_o       = calc_status_cast_i.mem3_miss_v;

assign chk_poison_iss_o = mispredict_v
                          | flush_i
                          | calc_status_cast_i.mem3_miss_v;
                          
assign chk_poison_isd_o = mispredict_v
                          | flush_i
                          | calc_status_cast_i.mem3_miss_v;

assign chk_poison_ex1_o = mispredict_v
                          | flush_i
                          | calc_status_cast_i.mem3_miss_v;

assign chk_poison_ex2_o = flush_i
                          | calc_status_cast_i.mem3_miss_v;

endmodule

