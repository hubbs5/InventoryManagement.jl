using Distributions
using InventoryManagement

#define network connectivity
net = MetaDiGraph(path_digraph(2)) # 1 -> 2
materials = [:A]
bom = [0]
set_prop!(net, :materials, materials)
set_prop!(net, :bill_of_materials, bom)

#specify parameters, holding costs and capacity, market demands and penalty for unfilfilled demand
set_props!(net, 1, Dict(:initial_inventory => Dict(:A => Inf),
                        :inventory_capacity => Dict(:A => Inf),
                        :holding_cost => Dict(:A => 0)))

set_props!(net, 2, Dict(:initial_inventory => Dict(:A => 100),
                        :inventory_capacity => Dict(:A => Inf),
                        :holding_cost => Dict(:A => 0.01),
                        :demand_distribution => Dict(:A => Normal(5,0.5)),
                        :demand_frequency => Dict(:A => 0.5),
                        :sales_price => Dict(:A => 3),
                        :demand_penalty => Dict(:A => 0.01),
                        :supplier_priority => Dict(:A => [1])))

#specify sales prices, transportation costs, lead time
set_props!(net, 1, 2, Dict(:sales_price => Dict(:A => 2),
                          :transportation_cost => Dict(:A => 0.01),
                          :lead_time => Dict(:A => Poisson(5))))

#create environment
num_periods = 100
env = SupplyChainEnv(net, num_periods, backlog = true)

#define reorder policy parameters
policy = :rQ #(s, S) policy
freq = 25 #review every 25 periods
r = Dict((2,:A) => 20) #lower bound on inventory
Q = Dict((2,:A) => 80) #base stock level

#run simulation with reorder policy
simulate_policy!(env, r, Q, policy, freq)

#make plots
using StatsPlots
#unfulfilled
fig1 = plot(env.demand.period, env.demand.unfulfilled, linetype=:steppost, lab="backlog",
                    xlabel="period", ylabel="level", title="Node 2, Material A")
#add inventory position
inv_on_hand = filter(i -> i.level < Inf, env.inv_on_hand)
plot!(inv_on_hand.period, inv_on_hand.level, linetype=:steppost, lab = "on-hand inventory")
