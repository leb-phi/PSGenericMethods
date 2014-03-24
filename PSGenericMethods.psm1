function Invoke-GenericMethod
{
    <#
    .Synopsis
       Invokes Generic methods on .NET Framework types
    .DESCRIPTION
       Allows the caller to invoke a Generic method on a .NET object or class with a single function call.  Invoke-GenericMethod handles identifying the proper method overload, parameters with default values, and to some extent, the same type conversion behavior you expect when calling a normal .NET Framework method from PowerShell.
    .PARAMETER InputObject
       The object on which to invoke an instance generic method.
    .PARAMETER Type
       The .NET class on which to invoke a static generic method.
    .PARAMETER MethodName
       The name of the generic method to be invoked.
    .PARAMETER GenericType
       One or more types which are specified when calling the generic method.  For example, if a method's signature is "string MethodName<T>();", and you want T to be a String, then you would pass "string" or ([string]) to the Type parameter of Invoke-GenericMethod.
    .PARAMETER ArgumentList
       The arguments to be passed on to the generic method when it is invoked.  The order of the arguments must match that of the .NET method's signature; named parameters are not currently supported.
    .EXAMPLE
       Invoke-GenericMethod -InputObject $someObject -MethodName SomeMethodName -GenericType string -ArgumentList $arg1,$arg2,$arg3

       Invokes a generic method on an object.  The signature of this method would be something like this (containing 3 arguments and a single Generic type argument):  object SomeMethodName<T>(object arg1, object arg2, object arg3);
    .EXAMPLE
       $someObject | Invoke-GenericMethod -MethodName SomeMethodName -GenericType string -ArgumentList $arg1,$arg2,$arg3

       Same as example 1, except $someObject is passed to the function via the pipeline.
    .EXAMPLE
       Invoke-GenericMethod -Type SomeClass -MethodName SomeMethodName -GenericType string,int -ArgumentList $arg1,$arg2,$arg3

       Invokes a static generic method on a class.  The signature of this method would be something like this (containing 3 arguments and two Generic type arguments):  static object SomeMethodName<T1,T2> (object arg1, object arg2, object arg3);
    .INPUTS
       System.Object
    .OUTPUTS
       System.Object
    .NOTES
       There are currently issues calling methods that contain arguments that are themselves Generic types.  While the functions resolve the runtime types of these generic arguments properly, invoking the method gives the following type of error:

       Exception calling "Invoke" with "2" argument(s): "Object of type 'System.Management.Automation.PSObject' cannot be converted to type 'System.Collections.Generic.List`1[System.String]'."

       This happens even when calling non-generic methods that contain generic type arguments via Reflection from PowerShell, such as:  static object SomeMethodName(List<string> list);
    #>

    [CmdletBinding(DefaultParameterSetName = 'Instance')]
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true, ParameterSetName = 'Instance')]
        $InputObject,

        [Parameter(Mandatory = $true, ParameterSetName = 'Static')]
        [Type]
        $Type,

        [Parameter(Mandatory = $true)]
        [string]
        $MethodName,

        [Parameter(Mandatory = $true)]
        [Type[]]
        $GenericType,

        [Object[]]
        $ArgumentList = @()
    )

    process
    {
        switch ($PSCmdlet.ParameterSetName)
        {
            'Instance'
            {
                $_type  = $InputObject.GetType()
                $object = $InputObject
                $flags  = [System.Reflection.BindingFlags] 'Instance, Public'
            }

            'Static'
            {
                $_type  = $Type
                $object = $null
                $flags  = [System.Reflection.BindingFlags] 'Static, Public'
            }
        }

        $argList = $argumentList.Clone()

        $params = @{
            Type         = $_type
            BindingFlags = $flags
            MethodName   = $MethodName
            GenericType  = $GenericType
            ArgumentList = [ref]$argList
        }

        $method = Get-GenericMethod @params

        if ($null -eq $method)
        {
            Write-Error "No matching method was found"
            return
        }

        # I'm not sure why, but PowerShell appears to be passing instances of PSObject when $argList contains generic types.  Instead of calling
        # $method.Invoke here from PowerShell, I had to write the PSGenericMethods.MethodInvoker.InvokeMethod helper code in C# to enumerate the
        # argument list and replace any instances of PSObject with their BaseObject before calling $method.Invoke().

        return [PSGenericMethods.MethodInvoker]::InvokeMethod($method, $object, $argList)

    } # process

} # function Invoke-GenericMethod

function Get-GenericMethod
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [Type]
        $Type,

        [Parameter(Mandatory = $true)]
        [string]
        $MethodName,

        [Parameter(Mandatory = $true)]
        [Type[]]
        $GenericType,

        [ref]
        $ArgumentList,

        [System.Reflection.BindingFlags]
        $BindingFlags = [System.Reflection.BindingFlags]::Default,

        [switch]
        $WithCoercion
    )

    if ($null -eq $ArgumentList.Value)
    {
        $originalArgList = @()
    }
    else
    {
        $originalArgList = @($ArgumentList.Value)
    }

    foreach ($method in $Type.GetMethods($BindingFlags))
    {
        $argList = $originalArgList.Clone()

        if (-not $method.IsGenericMethod -or $method.Name -ne $MethodName) { continue }
        if ($GenericType.Count -ne $method.GetGenericArguments().Count) { continue }

        if (Test-GenericMethodParameters -ParameterList $method.GetParameters() -ArgumentList ([ref]$argList) -GenericType $GenericType -WithCoercion:$WithCoercion)
        {
            $ArgumentList.Value = $argList
            return $method.MakeGenericMethod($GenericType)
        }
    }

    if (-not $WithCoercion)
    {
        $null = $PSBoundParameters.Remove('WithCoercion')
        return Get-GenericMethod @PSBoundParameters -WithCoercion
    }

} # function Get-GenericMethod

function Test-GenericMethodParameters
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Reflection.ParameterInfo[]]
        $ParameterList,

        [ref]
        $ArgumentList,

        [Parameter(Mandatory = $true)]
        [Type[]]
        $GenericType,

        [switch]
        $WithCoercion
    )

    if ($null -eq $ArgumentList.Value)
    {
        $argList = @()
    }
    else
    {
        $argList = @($ArgumentList.Value)
    }

    if ($ParameterList.Count -lt $argList.Count) { continue }
    
    for ($i = 0; $i -lt $argList.Count; $i++)
    {
        $params = @{
            ParameterType = $ParameterList[$i].ParameterType
            RuntimeType   = $GenericType
            GenericType   = $method.GetGenericArguments()
        }

        $runtimeType = Resolve-RuntimeType @params

        if ($null -eq $runtimeType)
        {
            throw "Could not determine runtime type of parameter '$($ParameterList[$i].Name)'"
        }
            
        if ($runtimeType.FullName -like 'System.Nullable``1*')
        {
            if ($null -eq $argList[$i])
            {
                continue
            }
                
            $runtimeType = $runtimeType.GetGenericArguments()[0]
        }

        if ($null -eq $argList[$i])
        {
            if ($runtimeType.IsValueType) { return $false }
        }
        else
        {
            if ($argList[$i].GetType() -eq $runtimeType) { continue }

            $coercedValue = $argList[$i] -as $runtimeType
            if (-not $WithCoercion -or $null -eq $coercedValue)  { return $false }

            $argList[$i] = $coercedValue
        }                    

    } # for ($i = 0; $i -lt $argList.Count; $i++)

    $defaults = New-Object System.Collections.ArrayList

    for ($i = $argList.Count; $i -lt $ParameterList.Count; $i++)
    {
        if (-not $ParameterList[$i].HasDefaultValue)  { return $false }
        $null = $defaults.Add($ParameterList[$i].DefaultValue)
    }

    $ArgumentList.Value = $argList + $defaults.ToArray()
    
    return $true

} # function Test-GenericMethodParameters

function Resolve-RuntimeType
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [Type]
        $ParameterType,

        [Parameter(Mandatory = $true)]
        [Type[]]
        $RuntimeType,

        [Parameter(Mandatory = $true)]
        [Type[]]
        $GenericType
    )

    if ($ParameterType.IsGenericParameter)
    {
        for ($i = 0; $i -lt $GenericType.Count; $i++)
        {
            if ($ParameterType -eq $GenericType[$i])
            {
                return $RuntimeType[$i]
            }
        }
    }
    elseif ($ParameterType.ContainsGenericParameters)
    {
        $genericArguments = $ParameterType.GetGenericArguments()
        $runtimeArguments = New-Object System.Collections.ArrayList

        foreach ($argument in $genericArguments)
        {
            $null = $runtimeArguments.Add((Resolve-RuntimeType -ParameterType $argument -RuntimeType $RuntimeType -GenericType $GenericType))
        }

        $definition = $ParameterType
        if (-not $definition.IsGenericTypeDefinition)
        {
            $definition = $definition.GetGenericTypeDefinition()
        }

        return $definition.MakeGenericType($runtimeArguments.ToArray())
    }
    else
    {
        return $ParameterType
    }
}

Add-Type -ErrorAction Stop -TypeDefinition @'
    namespace PSGenericMethods
    {
        using System;
        using System.Reflection;
        using System.Management.Automation;

        public static class MethodInvoker
        {
            public static object InvokeMethod(MethodInfo method, object target, object[] arguments)
            {
                if (method == null) { throw new ArgumentNullException("method"); }

                object[] args = null;

                if (arguments != null)
                {
                    args = (object[])arguments.Clone();
                    for (int i = 0; i < args.Length; i++)
                    {
                        PSObject pso = args[i] as PSObject;
                        if (pso != null)
                        {
                            args[i] = pso.BaseObject;
                        }
                    }
                }

                return method.Invoke(target, args);
            }
        }
    }
'@

Export-ModuleMember -Function 'Invoke-GenericMethod'
