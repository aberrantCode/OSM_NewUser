using OsmUserWeb.Services;
using Xunit;

namespace OsmUserWeb.Tests;

// Tests for the three pure static methods on AdUserService that contain
// no AD I/O and can therefore run without a domain controller.

public class ResolveBaseNameTests
{
    [Fact]
    public void ExplicitBaseName_ReturnsTrimmed()
    {
        var result = AdUserService.ResolveBaseName("  alice  ", "SOMEUSER1");
        Assert.Equal("alice", result);
    }

    [Fact]
    public void NullBaseName_StripsSuffixDigitsFromProcessUser()
    {
        var result = AdUserService.ResolveBaseName(null, "jdoe42");
        Assert.Equal("jdoe", result);
    }

    [Fact]
    public void EmptyBaseName_StripsSuffixDigitsFromProcessUser()
    {
        var result = AdUserService.ResolveBaseName("", "admin99");
        Assert.Equal("admin", result);
    }

    [Fact]
    public void WhitespaceBaseName_StripsSuffixDigitsFromProcessUser()
    {
        var result = AdUserService.ResolveBaseName("   ", "svc007");
        Assert.Equal("svc", result);
    }

    [Fact]
    public void ProcessUserWithNoDigits_ReturnsProcessUser()
    {
        var result = AdUserService.ResolveBaseName(null, "alice");
        Assert.Equal("alice", result);
    }

    [Fact]
    public void ProcessUserAllDigits_Throws()
    {
        var ex = Assert.Throws<ArgumentException>(
            () => AdUserService.ResolveBaseName(null, "12345"));

        Assert.Contains("empty string", ex.Message);
    }

    [Fact]
    public void ProcessUserEmpty_Throws()
    {
        var ex = Assert.Throws<ArgumentException>(
            () => AdUserService.ResolveBaseName(null, ""));

        Assert.Contains("empty string", ex.Message);
    }
}

public class ComputeNextNumberTests
{
    [Fact]
    public void EmptyList_ReturnsOne()
    {
        var result = AdUserService.ComputeNextNumber("alice", []);
        Assert.Equal(1, result);
    }

    [Fact]
    public void SingleMatch_ReturnsMaxPlusOne()
    {
        var result = AdUserService.ComputeNextNumber("alice", ["alice3"]);
        Assert.Equal(4, result);
    }

    [Fact]
    public void MultipleMatches_ReturnsMaxPlusOne()
    {
        var result = AdUserService.ComputeNextNumber("alice", ["alice1", "alice3", "alice2"]);
        Assert.Equal(4, result);
    }

    [Fact]
    public void NonMatchingNames_AreIgnored()
    {
        // "bob1" should not affect alice's counter
        var result = AdUserService.ComputeNextNumber("alice", ["bob1", "alice2"]);
        Assert.Equal(3, result);
    }

    [Fact]
    public void CaseInsensitiveMatch()
    {
        var result = AdUserService.ComputeNextNumber("alice", ["ALICE5"]);
        Assert.Equal(6, result);
    }

    [Fact]
    public void PartialMatchNotCounted()
    {
        // "xalice1" does not start with "alice", so it should be ignored
        var result = AdUserService.ComputeNextNumber("alice", ["xalice1"]);
        Assert.Equal(1, result);
    }

    [Fact]
    public void NameWithoutTrailingNumber_IsIgnored()
    {
        // "alice" with no suffix digit should not match
        var result = AdUserService.ComputeNextNumber("alice", ["alice"]);
        Assert.Equal(1, result);
    }
}

public class FormatMemberOfTests
{
    [Fact]
    public void EmptyCollection_ReturnsEmptyString()
    {
        var result = AdUserService.FormatMemberOf([]);
        Assert.Equal(string.Empty, result);
    }

    [Fact]
    public void SingleName_ReturnsThatName()
    {
        var result = AdUserService.FormatMemberOf(["Domain Admins"]);
        Assert.Equal("Domain Admins", result);
    }

    [Fact]
    public void MultipleNames_JoinedWithCommaSpace()
    {
        var result = AdUserService.FormatMemberOf(["GroupA", "GroupB", "GroupC"]);
        Assert.Equal("GroupA, GroupB, GroupC", result);
    }

    [Fact]
    public void NullEntries_AreFiltered()
    {
        var result = AdUserService.FormatMemberOf(["GroupA", null, "GroupC"]);
        Assert.Equal("GroupA, GroupC", result);
    }

    [Fact]
    public void EmptyStringEntries_AreFiltered()
    {
        var result = AdUserService.FormatMemberOf(["GroupA", "", "GroupC"]);
        Assert.Equal("GroupA, GroupC", result);
    }

    [Fact]
    public void AllNullsOrEmpty_ReturnsEmptyString()
    {
        var result = AdUserService.FormatMemberOf([null, "", null]);
        Assert.Equal(string.Empty, result);
    }
}
