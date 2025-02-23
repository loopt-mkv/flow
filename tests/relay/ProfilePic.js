/**
 * @format
 * @flow
 */

import * as React from 'react';
import {createFragmentContainer, type GetPropFragmentRef} from './Relay';

import type {ProfilePic_image} from './ProfilePic.graphql';

type Props = {
  image: ProfilePic_image,
};

class ProfilePic extends React.Component<Props> {
  render(): React.Node {
    (this.props.image.url: empty); // Error: string ~> empty
    return <img src={this.props.image.url} />;
  }
}

export default (createFragmentContainer(ProfilePic): React.ComponentType<
  $ObjMap<Props, GetPropFragmentRef>,
>);
