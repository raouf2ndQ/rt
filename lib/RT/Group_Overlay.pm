# $Header: /raid/cvsroot/rt/lib/RT/Group.pm,v 1.3 2001/12/14 19:03:08 jesse Exp $
# Copyright 1996-2002 Jesse Vincent <jesse@bestpractical.com>
# Released under the terms of version 2 of the GNU Public License

=head1 NAME

  RT::Group - RT\'s group object

=head1 SYNOPSIS

  use RT::Group;
my $group = new RT::Group($CurrentUser);

=head1 DESCRIPTION

An RT group object.

=head1 AUTHOR

Jesse Vincent, jesse@bestpractical.com

=head1 SEE ALSO

RT

=head1 METHODS


=begin testing

ok (require RT::Group);

ok (my $group = RT::Group->new($RT::SystemUser), "instantiated a group object");
ok (my ($id, $msg) = $group->Create( Name => 'TestGroup', Description => 'A test group',
                    Domain => 'System', Instance => ''), 'Created a new group');
ok ($id != 0, "Group id is $id");
ok ($group->Name eq 'TestGroup', "The group's name is 'TestGroup'");
my $ng = RT::Group->new($RT::SystemUser);

ok($ng->LoadSystemGroup('TestGroup'), "Loaded testgroup");
ok(($ng->id == $group->id), "Loaded the right group");
ok ($ng->AddMember('1' ), "Added a member to the group");
ok ($ng->AddMember('2' ), "Added a member to the group");
ok ($ng->AddMember('3' ), "Added a member to the group");

my $group_2 = RT::Group->new($RT::SystemUser);
ok (my ($id_2, $msg_2) = $group_2->Create( Name => 'TestGroup2', Description => 'A second test group',
                    Domain => 'System', Instance => ''), 'Created a new group');
ok ($id_2 != 0, "Created group 2 ok");
ok ($group_2->AddMember($ng->PrincipalId), "Made TestGroup a member of testgroup2");
ok ($group_2->AddMember('1' ), "Added  member RT_System to the group TestGroup2");

my $group_3 = RT::Group->new($RT::SystemUser);
ok (($id_3, $msg) = $group_3->Create( Name => 'TestGroup3', Description => 'A second test group',
                    Domain => 'System', Instance => ''), 'Created a new group');
ok ($id_3 != 0, "Created group 3 ok");
ok ($group_3->AddMember($group_2->PrincipalId), "Made TestGroup a member of testgroup2");

my $principal_1 = RT::Principal->new($RT::SystemUser);
$principal_1->Load('1');

my $principal_2 = RT::Principal->new($RT::SystemUser);
$principal_2->Load('2');

ok ($group_3->AddMember('1' ), "Added  member RT_System to the group TestGroup2");
ok($group_3->HasMember($principal_2) eq undef, "group 3 doesn't have member 2");
ok($group_3->HasMemberRecursively($principal_2) eq undef, "group 3 has member 2 recursively");


ok($ng->HasMember($principal_2) , "group ".$ng->Id." has member 2");
my ($delid , $delmsg) =$ng->DeleteMember($principal_2->Id);
ok ($delid !=0, "Sucessfully deleted it-".$delid."-".$delmsg);


ok($group_3->HasMemberRecursively($principal_2) == undef, "group 3 doesn't have member 2");
ok($group_2->HasMemberRecursively($principal_2) == undef, "group 2 doesn't have member 2");
ok($ng->HasMember($principal_2) == undef, "group 1 doesn't have member 2");;
ok($group_3->HasMemberRecursively($principal_2) == undef, "group 3 has member 2 recursively");


=end testing



=cut

no warnings qw(redefine);

use RT::GroupMembers;
use RT::Principals;
use RT::ACL;

# {{{ sub Load 

=head2 Load

Load a group object from the database. Takes a single argument.
If the argument is numerical, load by the column 'id'. Otherwise, load by
the "Name" column which is the group's textual name

=cut

sub Load {
    my $self       = shift;
    my $identifier = shift || return undef;

    #if it's an int, load by id. otherwise, load by name.
    if ( $identifier !~ /\D/ ) {
        $self->SUPER::LoadById($identifier);
    }
    else {
        $self->LoadByCol( "Name", $identifier );
    }
}

# }}}

# {{{ sub LoadSystemGroup 

=head2 LoadSystemGroup NAME

Loads a system group from the database. The only argument is
the group's name.


=cut

sub LoadSystemGroup {
    my $self       = shift;
    my $identifier = shift;

        $self->LoadByCols( "Domain" => 'System',
                           "Instance" => '',
                           "Name" => $identifier );
}

# }}}

# {{{ sub Create

=head2 Create

Takes a paramhash with named arguments: Name, Description.

TODO: fill in for 2.2

=cut

sub Create {
    my $self = shift;
    my %args = (
        Name        => undef,
        Description => undef,
        Domain      => undef,
        Instance    => undef,
        @_
    );

    # TODO: set up acls to deal based on what sort of group is being created
    unless ( $self->CurrentUser->HasSystemRight('AdminGroups') ) {
        $RT::Logger->warning( $self->CurrentUser->Name
              . " Tried to create a group without permission." );
        return ( 0, 'Permission Denied' );
    }

    $RT::Handle->BeginTransaction();

    my $id = $self->SUPER::Create(
        Name        => $args{'Name'},
        Description => $args{'Description'},
        Domain      => $args{'Domain'},
        Instance    => $args{'Instance'}
    );

    unless ($id) {
        return ( 0, $self->loc('Could not create group') );
    }

    # Groups deal with principal ids, rather than user ids.
    # When creating this user, set up a principal Id for it.
    my $principal    = RT::Principal->new( $self->CurrentUser );
    my $principal_id = $principal->Create(
        PrincipalType => 'Group',
        ObjectId      => $id
    );

    # If we couldn't create a principal Id, get the fuck out.
    unless ($principal_id) {
        $RT::Handle->Rollback();
        $self->crit(
            "Couldn't create a Principal on new user create. Strange thi
ngs are afoot at the circle K" );
        return ( 0, $self->loc('Could not create group') );
    }

    $RT::Handle->Commit();
    return ( $id, $self->loc("Group created") );
}

# }}}

# {{{ sub Delete

=head2 Delete

Delete this object

=cut

sub Delete {
    my $self = shift;

    unless ( $self->CurrentUser->HasSystemRight('AdminGroups') ) {
        return ( 0, 'Permission Denied' );
    }

    return ( $self->SUPER::Delete(@_) );
}

# }}}

# {{{ MembersObj

=head2 MembersObj

Returns an RT::Principals object of this group's members.

=cut

sub MembersObj {
    my $self = shift;
    unless ( defined $self->{'members_obj'} ) {
        $self->{'members_obj'} = RT::GroupMembers->new( $self->CurrentUser );

        #If we don't have rights, don't include any results
        $self->{'members_obj'}->LimitToMembersOfGroup( $self->PrincipalId );

    }
    return ( $self->{'members_obj'} );

}

# }}}

# {{{ AddMember

=head2 AddMember PRINCIPAL_ID

AddMember adds a principal to this group.  It takes a single principal id.
Returns a two value array. the first value is true on successful 
addition or 0 on failure.  The second value is a textual status msg.

R


=cut

sub AddMember {
    my $self       = shift;
    my $new_member = shift;

    my $new_member_obj = RT::Principal->new( $self->CurrentUser );
    $new_member_obj->Load($new_member);

    unless ( $self->CurrentUser->HasSystemRight('AdminGroups') ) {

        #User has no permission to be doing this
        return ( 0, $self->loc("Permission Denied") );
    }

    unless ( $new_member_obj->Id ) {
        $RT::Logger->debug("Couldn't find that principal");
        return ( 0, $self->loc("Couldn't find that principal") );
    }

    if ( $self->HasMember( $new_member_obj ) ) {

        #User is already a member of this group. no need to add it
        return ( 0, $self->loc("Group already has member") );
    }

    my $member_object = RT::GroupMember->new( $self->CurrentUser );
    $member_object->Create(
        Member => $new_member_obj,
        Group => $self->PrincipalObj
    );
    return ( 1, "Member added" );
}

# }}}

# {{{ HasMember

=head2 HasMember RT::Principal

Takes an RT::Principal object returns a GroupMember Id if that user is a 
member of this group.
Returns undef if the user isn't a member of the group or if the current
user doesn't have permission to find out. Arguably, it should differentiate
between ACL failure and non membership.

=cut

sub HasMember {
    my $self    = shift;
    my $principal = shift;


    unless (UNIVERSAL::isa($principal,'RT::Principal')) {
        $RT::Logger->crit("Group::HasMember was called with an argument that".
                          "isn't an RT::Principal. It's $principal");
        return(undef);
    }

    my $member_obj = RT::GroupMember->new( $self->CurrentUser );
    $member_obj->LoadByCols( MemberId => $principal->id, 
                             GroupId => $self->PrincipalId );

    #If we have a member object
    if ( defined $member_obj->id ) {
        return ( $member_obj->id );
    }

    #If Load returns no objects, we have an undef id. 
    else {
        $RT::Logger->debug($self." does not contain principal ".$principal->id);
        return (undef);
    }
}

# }}}

# {{{ HasMemberRecursively

=head2 HasMemberRecursively RT::Principal

Takes an RT::Principal object and returns a GroupMember Id if that user is a member of 
this group.
Returns undef if the user isn't a member of the group or if the current
user doesn't have permission to find out. Arguably, it should differentiate
between ACL failure and non membership.

=cut

sub HasMemberRecursively {
    my $self    = shift;
    my $principal = shift;

    unless (UNIVERSAL::isa($principal,'RT::Principal')) {
        $RT::Logger->crit("Group::HasMember was called with an argument that".
                          "isn't an RT::Principal. It's $principal");
        return(undef);
    }

    my $member_obj = RT::GroupMember->new( $self->CurrentUser );
    $member_obj->LoadByCols( MemberId => $principal->Id,
                             GroupId => $self->PrincipalId );

    #If we have a member object
    if ( defined $member_obj->id ) {
        return ( $member_obj->id );
    }

    #If Load returns no objects, we have an undef id. 
    else {
        return (undef);
    }
}

# }}}

# {{{ DeleteMember

=head2 DeleteMember PRINCIPAL_ID

Takes the user id of a member.
If the current user has apropriate rights,
removes that GroupMember from this group.
Returns a two value array. the first value is true on successful 
addition or 0 on failure.  The second value is a textual status msg.

=cut

sub DeleteMember {
    my $self   = shift;
    my $member_id = shift;

    $RT::Logger->debug("About to try to delete principal $member_id  as a".
                        "member of group ".$self->Id);

    unless ( $self->CurrentUser->HasSystemRight('AdminGroups') ) {
        return ( 0, $self->loc("Permission Denied"));
    }

    my $member_obj =  RT::GroupMember->new( $self->CurrentUser );
    
    $member_obj->LoadByCols( MemberId  => $member_id,
                             GroupId => $self->PrincipalId);

    $RT::Logger->debug("Loaded the RT::GroupMember object ".$member_obj->id);

    #If we couldn't load it, return undef.
    unless ( $member_obj->Id() ) {
        $RT::Logger->debug("Group has no member with that id");
        return ( 0,$self->loc( "Group has no such member" ));
    }

    #Now that we've checked ACLs and sanity, delete the groupmember
    my $val = $member_obj->Delete();

    if ($val) {
        $RT::Logger->debug("Deleted group ".$self->Id." member ". $member_id);
     
        return ( $val, $self->loc("Member deleted") );
    }
    else {
        $RT::Logger->debug("Failed to delete group ".$self->Id." member ". $member_id);
        return ( 0, $self->loc("Member not deleted" ));
    }
}

# }}}

# {{{ ACL Related routines

# {{{ GrantQueueRight

=head2 GrantQueueRight

Grant a queue right to this group.  Takes a paramhash of which the elements
RightAppliesTo and RightName are important.

=cut

sub GrantQueueRight {

    my $self = shift;
    my %args = (
        RightScope     => 'Queue',
        RightName      => undef,
        RightAppliesTo => undef,
        PrincipalType  => 'Group',
        PrincipalId    => $self->PrincipalId,
        @_
    );

    #ACLs get checked in ACE.pm

    my $ace = new RT::ACE( $self->CurrentUser );

    return ( $ace->Create(%args) );
}

# }}}

# {{{ GrantSystemRight

=head2 GrantSystemRight

Grant a system right to this group. 
The only element that's important to set is RightName.

=cut

sub GrantSystemRight {

    my $self = shift;
    my %args = (
        RightScope     => 'System',
        RightName      => undef,
        RightAppliesTo => 0,
        PrincipalType  => 'Group',
        PrincipalId    => $self->PrincipalId,
        @_
    );

    # ACLS get checked in ACE.pm

    my $ace = new RT::ACE( $self->CurrentUser );
    return ( $ace->Create(%args) );
}

# }}}

# {{{ sub _Set
sub _Set {
    my $self = shift;

    unless ( $self->CurrentUser->HasSystemRight('AdminGroups') ) {
        return ( 0, 'Permission Denied' );
    }

    return ( $self->SUPER::_Set(@_) );

}

# }}}

# }}}

# {{{ Principal related routines

=head2 PrincipalObj 

Returns the principal object for this user. returns an empty RT::Principal
if there's no principal object matching this user. 
The response is cached. PrincipalObj should never ever change.

=begin testing

ok(my $u = RT::Group->new($RT::SystemUser));
ok($u->Load(4), "Loaded the first user");
ok($u->PrincipalObj->ObjectId == 4, "user 4 is the fourth principal");
ok($u->PrincipalObj->PrincipalType eq 'Group' , "Principal 4 is a group");

=end testing

=cut


sub PrincipalObj {
    my $self = shift;
    unless ($self->{'PrincipalObj'} &&
            ($self->{'PrincipalObj'}->ObjectId == $self->Id) &&
            ($self->{'PrincipalObj'}->PrincipalType eq 'Group')) {

            $self->{'PrincipalObj'} = RT::Principal->new($self->CurrentUser);
            $self->{'PrincipalObj'}->LoadByCols('ObjectId' => $self->Id,
                                                'PrincipalType' => 'Group') ;
            }
    return($self->{'PrincipalObj'});
}


=head2 PrincipalId  

Returns this user's PrincipalId

=cut

sub PrincipalId {
    my $self = shift;
    return $self->PrincipalObj->Id;
}

# }}}
1;

