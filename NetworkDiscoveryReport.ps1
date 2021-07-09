$ProdSubscriptionIDs = @()
$NonProdSubscriptionIDs = @()

function ExpandIPAddress {
    param(
        $IPAddress
    )
    if($IPAddress.Contains('.')) {
        $Segments = $IPAddress.Split('.')
        return @([int]$Segments[0], [int]$Segments[1], [int]$Segments[2], [int]$Segments[3])
    }
    else {
        $Segments = $IPAddress.Split(':')
        $ExpandedAddress = @()
        foreach($Segment in $Segments) {
            if($Segment -eq "") {
                for($i = 0; $i -le 8 - $Segments.Count; $i += 1) {
                    $ExpandedAddress += [int]0
                }
            }
            else {
                $ExpandedAddress += [int]("0x" + $Segment)
            }
        }
        return $ExpandedAddress
    }
}

function ExpandIPRange {
    param(
        $CIDRRange
    )
    $RangeComponents = $CIDRRange.Split('/')
    $StartAddress = ExpandIPAddress $RangeComponents[0]
    $Segments = $StartAddress.Count
    $Mask = @([Math]::Floor(($RangeComponents[1] / (2 * $Segments))), ((2 * $Segments) - $RangeComponents[1] % (2 * $Segments)))
    $MaskAddress = @(0) * $Segments
    $EndAddress = @(0) * $Segments
    for($i = 0; $i -lt $Segments; $i += 1) {
        if($i -eq $Mask[0]) {
            $MaskAddress[$i] = [Math]::Pow(2, $Mask[1]) - 1
        }
        elseif($i -gt $Mask[0]) {
            $MaskAddress[$i] = [Math]::Pow(2, 2 * $Segments) - 1
        }
        if($MaskAddress[$i]) {
            $StartAddress[$i] -= $StartAddress[$i] % ($MaskAddress[$i] + 1)
        }
        $EndAddress[$i] = $StartAddress[$i] + $MaskAddress[$i]
    }
    return @($StartAddress, $EndAddress)
}

function IPAddressInRange {
    param(
        $IPAddress,
        $CIDRRange
    )
    $InRange = $True
    for($i = 0; $i -lt $IPAddress.Count; $i += 1) {
        $InRange = $InRange -and $CIDRRange[0][$i] -le $IPAddress[$i] -and $IPAddress[$i] -le $CIDRRange[1][$i]
    }
    return $InRange
}

function IPRangeInRange {
    param(
        $InnerRange,
        $OuterRange
    )
    return $(IPAddressInRange $InnerRange[0] $OuterRange) -and $(IPAddressInRange $InnerRange[1] $OuterRange)
}

$connection = Get-AutomationConnection -Name AzureRunAsConnection
Connect-AzureRMAccount -ServicePrincipal -Tenant $connection.TenantID -ApplicationId $connection.ApplicationID -CertificateThumbprint $connection.CertificateThumbprint | Out-Null
$SubscriptionIDs = $(Get-AzureRMSubscription -TenantID $connection.TenantID).ID

$ReportObject = @{}
$RTObjects = @{}
$PIPObjects = @{}
$NICAssignmentObjects = @{}
$PrivateLBObjects = @{}
$PrivateAppGWObjects = @{}

foreach($SubscriptionID in $SubscriptionIDs) {
    $PIPs = Get-AzureRMPublicIPAddress
    foreach($PIP in $PIPs) {
        $PIPObjects.($PIP.ID) = @{
            ID = $PIP.ID
            Name = $PIP.Name
            Allocation = $PIP.PublicIPAllocationMethod
            Address = $PIP.IPAddress
        }
    }
}

foreach($SubscriptionID in $SubscriptionIDs) {
    Set-AzureRMContext -Subscription $SubscriptionID | Out-Null
    $SubscriptionType = "Unknown"
    if($ProdSubscriptionIDs -contains $SubscriptionID) {
        $SubscriptionType = "Production"
    }
    elseif($NonProdSubscriptionIDs -contains $SubscriptionID) {
        $SubscriptionType = "Non-Production"
    }
    $RTs = Get-AzureRMRouteTable
    foreach($RT in $RTs) {
        $RTObject = @{
            ID = $RT.ID
            Name = $RT.Name
            Classification = "Private"
            Routes = @()
        }
        foreach($Route in $RT.Routes) {
            $RouteObject = Select-Object -InputObject $Route -Property Name, AddressPrefix, NextHopType, NextHopIPAddress
            $RTObject.Routes = $RTObject.Routes + $RouteObject
            if($RouteObject.NextHopType -eq "Internet") {
                $RTObject.Classification = "Public"
            }
        }
        $RTObjects.($RTObject.ID) = $RTObject
    }
    $NICs = Get-AzureRMNetworkInterface
    foreach($NIC in $NICs) {
        if($NIC.VirtualMachine) {
            foreach($IPConfig in $NIC.IPConfigurations) {
                if(-not $NICAssignmentObjects.($IPConfig.Subnet.ID)) {
                    $NICAssignmentObjects.($IPConfig.Subnet.ID) = @{
                        VMNICCount = 0
                        PublicIPVMs = @()
                    }
                }
                $NICAssignmentObjects.($IPConfig.Subnet.ID).VMNICCount = $NICAssignmentObjects.($IPConfig.Subnet.ID).VMNICCount + 1
                if($IPConfig.PublicIPAddress.ID) {
                    $PIPVMObject = @{
                        VM = @{
                            ID = $NIC.VirtualMachine.ID
                            Name = $NIC.VirtualMachine.ID.Substring($NIC.VirtualMachine.ID.LastIndexOf('/') + 1)
                        }
                        PIP = $PIPObjects.($IPConfig.PublicIPAddress.ID)
                    }
                    $NICAssignmentObjects.($IPConfig.Subnet.ID).PublicIPVMs = $NICAssignmentObjects.($IPConfig.Subnet.ID).PublicIPVMs + $PIPVMObject
                }
            }
        }
    }
    $LBs = Get-AzureRMLoadBalancer
    foreach($LB in $LBs) {
        foreach($IPConfig in $LB.FrontendIpConfigurations) {
            $LBObject = @{
                ID = $LB.ID
                Name = $LB.Name
                Type = "loadBalancers"
                BackendTargets = @()
            }
            foreach($BEPool in $LB.BackendAddressPools) {
                foreach($BETarget in $BEPool.BackendIPConfigurations) {
                    $BETargetParse = $BETarget.ID.Split('/')
                    $LBObject.BackendTargets = $LBObject.BackendTargets + @{
                        ID = $BETarget.ID
                        Name = $BETargetParse[8]
                        Type = $BETargetParse[7]
                    }
                }
            }
            if($IPConfig.Subnet) {
                if(-not $PrivateLBObjects.($IPConfig.Subnet.ID)){
                    $PrivateLBObjects.($IPConfig.Subnet.ID) = @()
                }
                $PrivateLBObjects.($IPConfig.Subnet.ID) = $PrivateLBObjects.($IPConfig.Subnet.ID) + $LBObject
            }
            if($IPConfig.PublicIPAddress) {
                if(-not $ReportObject.($LB.Location)) {
                    $ReportObject.($LB.Location) = @{}
                }
                if(-not $ReportObject.($LB.Location).($SubscriptionType)) {
                    $ReportObject.($LB.Location).($SubscriptionType) = @{
                        VNets = @()
                        Peerings = @()
                        LoadBalancers = @()
                        VPNs = @()
                        ExpressRoutes = @()
                    }
                }
                $ReportObject.($LB.Location).($SubscriptionType).LoadBalancers = $ReportObject.($LB.Location).($SubscriptionType).LoadBalancers + $LBObject
            }
        }
    }
    $AppGWs = Get-AzureRMApplicationGateway
    foreach($AppGW in $AppGWs) {
        foreach($IPConfig in $AppGW.FrontendIpConfigurations) {
            $AppGWObject = @{
                ID = $AppGW.ID
                Name = $AppGW.Name
                Type = "applicationGateways"
                BackendTargets = @()
            }
            foreach($BEPool in $AppGW.BackendAddressPools) {
                foreach($BETarget in $BEPool.BackendIPConfigurations) {
                    $BETargetParse = $BETarget.ID.Split('/')
                    $AppGWObject.BackendTargets = $AppGWObject.BackendTargets + @{
                        ID = $BETarget.ID
                        Name = $BETargetParse[8]
                        Type = $BETargetParse[7]
                    }
                }
            }
            if($IPConfig.Subnet) {
                if(-not $PrivateAppGWObjects.($IPConfig.Subnet.ID)){
                    $PrivateAppGWObjects.($IPConfig.Subnet.ID) = @()
                }
                $PrivateAppGWObjects.($IPConfig.Subnet.ID) = $PrivateAppGWObjects.($IPConfig.Subnet.ID) + $AppGWObject
            }
            if($IPConfig.PublicIPAddress) {
                if(-not $ReportObject.($AppGW.Location)) {
                    $ReportObject.($AppGW.Location) = @{}
                }
                if(-not $ReportObject.($AppGW.Location).($SubscriptionType)) {
                    $ReportObject.($AppGW.Location).($SubscriptionType) = @{
                        VNets = @()
                        Peerings = @()
                        LoadBalancers = @()
                        VPNs = @()
                        ExpressRoutes = @()
                    }
                }
                $ReportObject.($AppGW.Location).($SubscriptionType).LoadBalancers = $ReportObject.($AppGW.Location).($SubscriptionType).LoadBalancers + $AppGWObject
            }
        }
    }
}

foreach($SubscriptionID in $SubscriptionIDs) {
    Set-AzureRMContext -Subscription $SubscriptionID | Out-Null
    $SubscriptionType = "Unknown"
    if($ProdSubscriptionIDs -contains $SubscriptionID) {
        $SubscriptionType = "Production"
    }
    elseif($NonProdSubscriptionIDs -contains $SubscriptionID) {
        $SubscriptionType = "Non-Production"
    }
    $VNets = Get-AzureRMVirtualNetwork
    foreach($VNet in $VNets) {
        $VNetObject = @{
            ID = $VNet.ID
            Name = $VNet.Name
            AddressPrefixes = @{}
        }
        foreach($AddressPrefix in $VNet.AddressSpace.AddressPrefixes) {
            $AddressPrefixSubnets = @()
            $AddressPrefixRange = ExpandIPRange $AddressPrefix
            foreach($Subnet in $VNet.Subnets) {
                if(IPRangeInRange $(ExpandIPRange $Subnet.AddressPrefix[0]) $AddressPrefixRange) {
                    $SubnetObject = @{
                        SubnetName = $Subnet.Name
                        AddressPrefix = $Subnet.AddressPrefix[0]
                    }
                    if($Subnet.RouteTable.ID) {
                        $SubnetObject.RouteTable = $RTObjects.($Subnet.RouteTable.ID)
                    }
                    if($NICAssignmentObjects.($Subnet.ID)) {
                        $SubnetObject.VMs = $NICAssignmentObjects.($Subnet.ID)
                    }
                    else {
                        $SubnetObject.VMs = @{}
                        $SubnetObject.VMs.VMNICCount = 0
                        $SubnetObject.VMs.PublicIPVMs = @()
                    }
                    if($PrivateLBObjects.($Subnet.ID)) {
                        $SubnetObject.LoadBalancers = $PrivateLBObjects.($Subnet.ID)
                    }
                    else {
                        $SubnetObject.LoadBalancers = @()
                    }
                    if($PrivateAppGWObjects.($Subnet.ID)) {
                        $SubnetObject.LoadBalancers = $PrivateAppGWObjects.($Subnet.ID)
                    }
                    $AddressPrefixSubnets = $AddressPrefixSubnets + $SubnetObject
                }
            }
            $VNetObject.AddressPrefixes.($AddressPrefix) = $AddressPrefixSubnets
        }
        if(-not $ReportObject.($VNet.Location)) {
            $ReportObject.($VNet.Location) = @{}
        }
        if(-not $ReportObject.($VNet.Location).($SubscriptionType)) {
            $ReportObject.($VNet.Location).($SubscriptionType) = @{
                VNets = @()
                Peerings = @()
                LoadBalancers = @()
                VPNs = @()
                ExpressRoutes = @()
            }
        }
        $ReportObject.($VNet.Location).($SubscriptionType).VNets = $ReportObject.($VNet.Location).($SubscriptionType).VNets + $VNetObject
        foreach($Peering in $VNet.VirtualNetworkPeerings) {
            $PeeringObject = @{
                VNetID = $VNet.ID
                VNetName = $VNet.Name
                RemoteVNetID = $Peering.RemoteVirtualNetwork.ID
                RemoteVNetName = $null
                AllowVNetAccess = $Peering.AllowVirtualNetworkAccess
                AllowForwardedTraffic = $Peering.AllowForwardedTraffic
                AllowGatewayTransit = $Peering.AllowGatewayTransit
                UseRemoteGateways = $Peering.UseRemoteGateways
            }
            if($PeeringObject.RemoteVNetID) {
                $PeeringObject.RemoteVNetName = $PeeringObject.RemoteVNetID.Substring($PeeringObject.RemoteVNetID.LastIndexOf('/') + 1)
            }
            $ReportObject.($VNet.Location).($SubscriptionType).Peerings = $ReportObject.($VNet.Location).($SubscriptionType).Peerings + $PeeringObject
        }
    }
    $RGs = $(Get-AzureRMResourceGroup).ResourceGroupName
    foreach($RG in $RGs) {
        $Gateways = Get-AzureRMVirtualNetworkGateway -ResourceGroupName $RG
        foreach($Gateway in $Gateways) {
            if(-not $ReportObject.($Gateway.Location)) {
                $ReportObject.($Gateway.Location) = @{}
            }
            if(-not $ReportObject.($VNet.Location).($SubscriptionType)) {
                $ReportObject.($Gateway.Location).($SubscriptionType) = @{
                    VNets = @()
                    Peerings = @()
                    LoadBalancers = @()
                    VPNs = @()
                    ExpressRoutes = @()
                }
            }
            $GatewayObject = @{
                ID = $Gateway.ID
                Name = $Gateway.Name
                PublicIPs = @()
                RouteTables = @()
            }
            foreach($IPConfig in $Gateway.IPConfigurations) {
                $GatewayObject.PublicIPs = $GatewayObject.PublicIPs + $PIPObjects.($IPConfig.PublicIPAddress.ID)
                $GatewayObject.RouteTables = $GatewayObject.RouteTables + $RTObjects.($IPConfig.Subnet.ID)
            }
            if($Gateway.GatewayType -eq "ExpressRoute") {
                $ReportObject.($Gateway.Location).($SubscriptionType).ExpressRoutes = $ReportObject.($Gateway.Location).($SubscriptionType).ExpressRoutes + $GatewayObject
            }
            else {
                $GatewayObject.VPNClientAddressPool = $Gateway.VPNClientConfiguration.VPNClientAddressPool
                $ReportObject.($Gateway.Location).($SubscriptionType).VPNs = $ReportObject.($Gateway.Location).($SubscriptionType).VPNs + $GatewayObject
            }
        }
    }
}

ConvertTo-JSON $ReportObject -Depth 100
