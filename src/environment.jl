abstract type AbstractEnv end

mutable struct SupplyChainEnv <: AbstractEnv
    network::MetaDiGraph #Supply Chain Network
    markets::Array #Array of markets (end distributors)
    producers::Array #Array of producer nodes
    distributors::Array #Array of distribution centers (excludes market nodes)
    materials::Array #Array of material names
    bill_of_materials::Array #Square matrix with BOM (rows = inputs, cols = ouputs); indices follow materials list; positive value is a co-product, negative is a input
    inv_on_hand::DataFrame #Timeseries On Hand Inventory @ each node
    inv_pipeline::DataFrame #Timeseries Pipeline Inventory on each arc
    inv_position::DataFrame #Timeseries Inventory Position for each node
    replenishments::DataFrame #Timeseries Replenishment orders placed on each arc
    shipments::DataFrame #Current shipments and time to arrival for each node
    production::DataFrame #Current material production commited to an arc and time to ship
    demand::DataFrame #Timeseries with realization of demand at each market
    profit::DataFrame #Timeseries with profit at each node
    reward::Float64 #Final reward in the system (used for RL)
    period::Int #period in the simulation
    num_periods::Int #number of periods in the simulation
    discount::Float64 #Time discount factor
    backlog::Bool #Backlogging allowed if true; otherwise, lost sales
    reallocate::Bool #reallocate unfulfilled requests if true
    seed::Int #Random seed
end

function SupplyChainEnv(network::MetaDiGraph, num_periods::Int;
                        discount::Float64=0.0, backlog::Bool=true,
                        reallocate::Bool=true,
                        seed::Int=0)
    #perform checks
        #order of materials in initial_inventory, production_capacity, market_demand and demand_frequency keys must be the same

    #get main nodes
    nodes = vertices(network)
    #get main edges
    arcs = [(e.src,e.dst) for e in edges(network)]
    #get end distributors, producers, and distribution centers
    mrkts = [n for n in nodes if isempty(outneighbors(network, n))] #markets must be sink nodes
    plants = [n for n in nodes if :production_cost in keys(network.vprops[n])]
    nonsources = [n for n in nodes if !isempty(inneighbors(network, n))]
    dcs = setdiff(nodes, mrkts, plants)
    #get materials
    mats = get_prop(network, :materials)
    bom = get_prop(network, :bill_of_materials)
    #check inputs
    if bom != [0] #if [0] then single product, no bom
        @assert typeof(bom) <: Matrix{T} where T <: Real "Bill of materials must be a matrix of real numbers."
        @assert size(bom)[1] == size(bom)[2] "Bill of materials must be a square matrix."
    end
    @assert size(bom)[1] == length(mats) "The number of rows and columns in the bill of materials must be equal to the number of materials."
    all_keys = [:initial_inventory, :inventory_capacity, :holding_cost]
    market_keys = [:demand_distribution, :demand_frequency, :sales_price, :demand_penalty]
    plant_keys = [:production_cost, :production_time, :production_capacity]
    arc_keys = [:sales_price, :transportation_cost, :lead_time]
    for n in nodes, key in all_keys
        @assert key in keys(network.vprops[n]) "$key not stored in distributor node $n."
        for p in mats
            @assert p in keys(network.vprops[n][key]) "Material $p not found in $key on node $n."
            @assert network.vprops[n][key][p] >= 0 "Parameter $key for material $p on node $n must be non-negative."
        end
    end
    for n in mrkts, key in market_keys
        @assert key in keys(network.vprops[n]) "$key not stored in market node $n."
        for p in mats
            @assert p in keys(network.vprops[n][key]) "Material $p not found in $key on node $n."
            if key == :demand_frequency
                @assert 0 <= network.vprops[n][key][p] <= 1 "Parameter $key for material $p on node $n must be between 0 and 1."
            elseif key == :demand_distribution
                @assert rand(network.vprops[n][key][p]) isa Number "Parameter $key for material $p on node $n must be a sampleable distribution or an array."
            else
                @assert network.vprops[n][key][p] >= 0 "Parameter $key for material $p on node $n must be non-negative."
            end
        end
    end
    for n in plants, key in plant_keys
        @assert key in keys(network.vprops[n]) "$key not stored in producer node $n."
        for p in mats
            @assert p in keys(network.vprops[n][key]) "Material $p not found in $key on node $n."
            @assert network.vprops[n][key][p] >= 0 "Parameter $key for material $p on node $n must be non-negative."
        end
    end
    for a in arcs, key in arc_keys
        @assert key in keys(network.eprops[Edge(a...)]) "$key not stored in arc $a."
        if key != :lead_time
            for p in mats
                @assert p in keys(network.eprops[Edge(a...)][key]) "Material $p not found in $key on arc $a."
                @assert network.eprops[Edge(a...)][key][p] >= 0 "Parameter $key for material $p on arc $a must be non-negative."
            end
        else
            @assert rand(network.eprops[Edge(a...)][key]) isa Number "Parameter $key on arc $a must be a sampleable distribution or an array."
        end
    end
    for n in nonsources, p in mats
        key = :supplier_priority
        @assert p in keys(network.vprops[n][key]) "Material $p not found in $key on node $n."
        for s in network.vprops[n][key][p]
            @assert s in inneighbors(network, n) "Supplier $s is not listed in the supplier priority for node $n for material $p."
        end
    end
    #create logging dataframes
    inv_on_hand = DataFrame(:period => Int[], :node => Int[], :material => [], :level => Float64[])
    for n in nodes, p in mats
        init_inv = get_prop(network, n, :initial_inventory)
        push!(inv_on_hand, (0, n, p, init_inv[p]))
    end
    inv_pipeline = DataFrame(:period => zeros(Int, length(mats)*length(arcs)),
                             :arc => repeat(arcs, inner = length(mats)),
                             :material => repeat(mats, outer = length(arcs)),
                             :level => zeros(length(mats)*length(arcs)))
    inv_position = copy(inv_on_hand)
    replenishments = DataFrame(:period => zeros(Int, length(mats)*length(arcs)),
                               :arc => repeat(arcs, inner = length(mats)),
                               :material => repeat(mats, outer = length(arcs)),
                               :amount => zeros(length(mats)*length(arcs)),
                               :lead => zeros(Int, length(mats)*length(arcs)))
    shipments = DataFrame(:arc => [],
                          :material => [],
                          :amount => Float64[],
                          :lead => Int[])
    production = DataFrame(:arc => [],
                           :material => [],
                           :amount => Float64[],
                           :lead => Int[])
    demand = DataFrame(:period => zeros(Int, length(mats)*length(mrkts)),
                       :node => repeat(mrkts, inner = length(mats)),
                       :material => repeat(mats, outer = length(mrkts)),
                       :demand => zeros(length(mats)*length(mrkts)),
                       :sale => zeros(length(mats)*length(mrkts)),
                       :unfulfilled => zeros(length(mats)*length(mrkts)),
                       :backlog => zeros(length(mats)*length(mrkts)))
    profit = DataFrame(:period => zeros(Int, length(nodes)),
                       :value => zeros(length(nodes)),
                       :node => nodes)
    reward = 0
    period = 0
    num_periods = num_periods
    env = SupplyChainEnv(network, mrkts, plants, dcs, mats, bom, inv_on_hand, inv_pipeline, inv_position,
                    replenishments, shipments, production, demand,
                    profit, reward, period, num_periods, discount, backlog, reallocate, seed)

    Random.seed!(env)

    return env
end

Random.seed!(env::SupplyChainEnv) = Random.seed!(env.seed)

function reset!(env::SupplyChainEnv)
    env.period = 0
    env.reward = 0
    filter!(i -> i.period == 0, env.inv_on_hand)
    filter!(i -> i.period == 0, env.inv_pipeline)
    filter!(i -> i.period == 0, env.inv_position)
    filter!(i -> i.period == 0, env.replenishments)
    filter!(i -> i.period == 0, env.demand)
    filter!(i -> i.period == 0, env.profit)
    env.shipments = DataFrame(:arc => [],
                          :material => [],
                          :amount => Float64[],
                          :lead => Int[])
    env.production = DataFrame(:arc => [],
                           :material => [],
                           :amount => Float64[],
                           :lead => Int[])

    Random.seed!(env)
end

is_terminated(env::SupplyChainEnv) = env.period == env.num_periods
